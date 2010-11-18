(in-package :cl-js)

(defun default-value (val &optional (hint :number))
  (block nil
    (unless (obj-p val) (return val))
    (when (vobj-p val) (return (vobj-value val)))
    (let ((first "toString") (second "valueOf"))
      (when (eq hint :number) (rotatef first second))
      (let ((method (js-prop val first)))
        (when (obj-p method)
          (let ((res (js-call method val)))
            (unless (obj-p res) (return res)))))
      (let ((method (js-prop val second)))
        (when (obj-p method)
          (let ((res (js-call method val)))
            (unless (obj-p res) (return res)))))
      (js-error :type-error "Can't convert object to ~a." (symbol-name hint)))))

(deftype js-number ()
  (if *float-traps*
      '(or number (member :Inf :-Inf :NaN))
      'number))

(defun read-num (str)
  (let ((result (with-input-from-string (in str) (read-js-number in))))
    (case result
      (:-infinity (-infinity))
      (:infinity (infinity))
      (t result))))

(defgeneric js-to-string (val)
  (:method (val) (error "No string conversion defined for value ~a" val)))

(defun to-string (val)
  (typecase val
    (string val)
    (js-number (cond ((is-nan val) "NaN")
                     ((eq val (infinity)) "Infinity")
                     ((eq val (-infinity)) "-Infinity")
                     ((integerp val) (princ-to-string val))
                     (t (format nil "~,,,,,,'eE" val))))
    (boolean (if val "true" "false"))
    (symbol (ecase val (:undefined "undefined") (:null "null")))
    (obj (to-string (default-value val :string)))
    (t (js-to-string val))))

(defgeneric js-to-number (val)
  (:method (val) (error "No number conversion defined for value ~a" val)))

(defun to-number (val)
  (typecase val
    (js-number val)
    (string (cond ((string= val "Infinity") (infinity))
                  ((string= val "-Infinity") (-infinity))
                  (t (or (read-num val) (nan)))))
    (boolean (if val 1 0))
    (symbol (ecase val (:undefined (nan)) (:null 0)))
    (obj (to-number (default-value val :number)))
    (t (js-to-number val))))

(defun to-integer (val)
  (typecase val
    (integer val)
    (js-number (cond ((is-nan val) 0)
                     ((eq val (infinity)) most-positive-fixnum)
                     ((eq val (-infinity)) most-negative-fixnum)
                     (t (truncate val))))
    (string (let ((read (read-num val)))
              (etypecase read (null 0) (integer read) (number (floor read)))))
    (boolean (if val 1 0))
    (symbol 0)
    (obj (to-integer (default-value val :number)))
    (t (floor (to-number val)))))

(defun to-int32 (val)
  (trunc32 (to-integer val)))

(defgeneric js-to-boolean (val)
  (:method (val) (declare (ignore val)) t))

(defun to-boolean (val)
  (typecase val
    (boolean val)
    (number (not (or (is-nan val) (zerop val))))
    (string (not (string= val "")))
    (symbol (case val (:Inf t) (:-Inf t) (t nil)))
    (obj t)
    (t (js-to-boolean val))))

(defun fvector (&rest elements)
  (let ((len (length elements)))
    (make-array len :fill-pointer len :initial-contents elements :adjustable t)))
(defun empty-fvector (len &optional fill-pointer)
  (make-array len :fill-pointer (or fill-pointer len) :initial-element :undefined :adjustable t))
(defun build-array (vector)
  (make-aobj (find-cls :array) vector))

(defun build-func (lambda)
  (make-fobj (find-cls :function) lambda nil))

(defun clip-index (index len)
  (max 0 (min index len)))

(defun lexical-eval (str scope)
  (let* ((str (to-string str))
         (parsed (parse/err str))
         (*scope* (list scope))
         (env-obj (car (captured-scope-objs scope)))
         (captured-locals (captured-scope-local-vars scope))
         (new-locals (and (not (eq captured-locals :null))
                          (set-difference (find-locals (second parsed)) captured-locals
                                          :key #'string=))))
    (declare (special *scope*))
    (dolist (local new-locals) (setf (js-prop env-obj local) :undefined))
    (or (compile-eval (translate-ast parsed)) :undefined)))

(defun make-js-error (type message &rest args)
  (let ((err (make-obj (or (find-cls type) (error "Bad JS-error type: ~a" type)))))
    (cached-set err "message" (if args (apply #'format nil message args) message))
    err))
(defun js-error (type message &rest args)
  (error 'js-condition :value (apply #'make-js-error type message args)))

(defun typed-value-of (obj type)
  (cond ((typep obj type) obj)
        ((and (vobj-p obj) (typep (vobj-value obj) type)) (vobj-value obj))
        (t (js-error :type-error "Incompatible type."))))

(declare-primitive-prototype string :string)
(declare-primitive-prototype number :number)
(declare-primitive-prototype (eql t) :boolean)
(declare-primitive-prototype (eql nil) :boolean)

(add-to-lib *stdlib*
  (.value "this" *env*)
  (.value "undefined" :undefined)
  (.value "Infinity" (infinity))
  (.value "NaN" (nan))

  (.func "parseInt" (val (radix 10))
    (or (parse-integer (to-string val) :junk-allowed t :radix (to-integer radix))
        (nan)))
  (.func "parseFloat" (val)
    (let ((val (to-string val)))
      (cond ((string= val "Infinity") (infinity))
            ((string= val "-Infinity") (-infinity))
            (t (or (read-num val) (nan))))))
  (.func "isNaN" (val) (is-nan (to-number val)))

  (.func "eval" (str)
    (or (compile-eval (translate (parse/err (to-string str)))) :undefined))

  (macrolet ((with-uri-err (&body body)
               `(handler-case (progn ,@body)
                  (url-encode:url-error (e) (js-error :uri-error (princ-to-string e))))))
    (.func "encodeURI" (str)
      (with-uri-err (url-encode:url-encode (to-string str) "%/?:@&=+$,#")))
    (.func "encodeURIComponent" (str)
      (with-uri-err (url-encode:url-encode (to-string str) "%/?:@&=+$,")))
    (.func "decodeURI" (str)
      (with-uri-err (url-encode:url-decode (to-string str) "/?:@&=+$,#")))
    (.func "decodeURIComponent" (str)
      (with-uri-err (url-encode:url-decode (to-string str) "")))))

(add-to-lib *stdlib*
  (.constructor "Object" (&rest args)
    (if args
        (make-vobj (find-cls :object) (car args))
        this)
    (:prototype :object)
    (:slot-default :noenum))

  (.prototype :object
    (:parent nil)
    (:slot-default :nodel)
    (.func "toString" () (if (obj-p this) "[object Object]" (to-string this)))
    (.func "toLocaleString" () (js-method this "toString"))
    (.func "valueOf" () this)

    (.func "hasOwnProperty" (prop) (and (obj-p this) (find-slot this (to-string prop)) t))
    (.func "propertyIsEnumerable" (prop)
      (and (obj-p this) (let ((slot (find-slot this (to-string prop))))
                          (and slot (not (logtest (cdr slot) +slot-noenum+)))))))

  (.constructor "Function" (&rest args)
    (let ((body (format nil "(function (~{~a~^, ~}) {~a});"
                        (mapcar 'to-string (butlast args)) (to-string (car (last args))))))
      (compile-eval (translate-ast (parse/err body))))
    (:prototype :function)
    (:make-new (constantly nil)))

  (flet ((vec-apply (func this vec)
           (macrolet ((vapply (n)
                        `(case (length vec)
                           ,@(loop :for i :below n :collect
                                `(,i (funcall func this ,@(loop :for j :below i :collect `(aref vec ,j)))))
                           (t (apply func this (coerce vec 'list))))))
             (vapply 7))))

    (.prototype :function
      (:slot-default :nodel)
      (.active "prototype"
        (:read () (let ((proto (js-obj)))
                    (ensure-slot proto "constructor" this +slot-noenum+)
                    (ensure-slot this "prototype" proto +slot-noenum+)
                    proto))
        (:write (val) (ensure-slot this "prototype" val +slot-noenum+)))

      (.func "apply" (self args)
        (typecase args
          (aobj (vec-apply (proc this) self (aobj-arr args)))
          (argobj (apply (proc this) self (argobj-list args)))
          (t (js-error :type-error "Second argument to Function.prototype.apply must be an array."))))
      (.func "call" (self &rest args)
        (apply (proc this) self args)))))

(add-to-lib *stdlib*
  (.constructor "Array" (&rest args)
    (let* ((len (length args))
           (arr (if (and (= len 1) (integerp (car args)))
                    (empty-fvector (car args))
                    (make-array len :initial-contents args :fill-pointer len :adjustable t))))
      (if (eq this *env*)
          (make-aobj (find-cls :array) arr)
          (progn (setf (aobj-arr this) arr) this)))
    (:prototype :array)
    (:make-new #'make-aobj))

  (macrolet ((unless-array (default &body body)
               `(if (aobj-p this) (progn ,@body) ,default)))

    (.prototype :array
      (:slot-default :nodel)
      (.active-r "length" (if (aobj-p this) (length (aobj-arr this)) 0))
      
      (.func "toString" () (js-method this "join"))

      (.func "concat" (&rest others)
        (let* ((elements (loop :for elt :in (cons this others) :collect
                            (if (aobj-p elt) (aobj-arr elt) (vector elt))))
               (size (reduce #'+ elements :key #'length))
               (arr (empty-fvector size))
               (pos 0))
          (dolist (elt elements)
            (loop :for val :across elt :do
               (setf (aref arr pos) val)
               (incf pos)))
          (build-array arr)))
      (.func "join" ((sep ","))
        (unless-array ""
          (let ((sep (to-string sep)))
            (with-output-to-string (out)
              (loop :for val :across (aobj-arr this) :for first := t :then nil :do
                 (unless first (write-string sep out))
                 (write-string (to-string val) out))))))

      (.func "splice" (index howmany &rest elems)
        (unless-array (build-array (fvector))
          (let* ((vec (aobj-arr this))
                 (index (clip-index (to-integer index) (length vec)))
                 (removed (clip-index (to-integer howmany) (- (length vec) index)))
                 (added (length elems))
                 (diff (- added removed))
                 (new-len (- (+ (length vec) added) removed))
                 (result (empty-fvector removed)))
            (replace result vec :start2 index :end2 (+ index removed))
            (cond ((< diff 0) ;; shrink
                   (replace vec vec :start1 (+ index added) :start2 (+ index removed))
                   (setf (fill-pointer vec) new-len))
                  ((> diff 0) ;; grow
                   (adjust-array vec new-len :fill-pointer new-len)
                   (replace vec vec :start1 (+ index added) :start2 (+ index removed))))
            (replace vec elems :start1 index)
            (build-array result))))

      (.func "pop" ()
        (unless-array :undefined
          (let ((vec (aobj-arr this)))
            (if (= (length vec) 0)
                :undefined
                (vector-pop vec)))))
      (.func "push" (&rest vals)
        (unless-array 0
          (let ((vec (aobj-arr this)))
            (dolist (val vals)
              (vector-push-extend val vec))
            (length vec))))

      (.func "shift" ()
        (unless-array :undefined
          (let* ((vec (aobj-arr this)) (len (length vec)))
            (if (> len 0)
                (let ((result (aref vec 0)))
                  (replace vec vec :start2 1)
                  (setf (fill-pointer vec) (1- len))
                  result)
                :undefined))))
      (.func "unshift" (val)
        (unless-array 0
          (let ((vec (aobj-arr this)))
            (setf (fill-pointer vec) (1+ (length vec)))
            (replace vec vec :start1 1)
            (setf (aref vec 0) val)
            (length vec))))

      (.func "slice" (from to)
        (let* ((len (to-integer (cached-lookup this "length")))
               (newarr (empty-fvector len 0))
               (ifrom (to-integer from))
               (from (clip-index (if (< ifrom 0) (+ len ifrom) ifrom) len))
               (ito (if (eq to :undefined) len (to-integer to)))
               (to (clip-index (if (< ito 0) (+ len ito) ito) len)))
          (loop :for i :from from :below to :do
             (if-not-found (elt (js-prop this i))
               nil
               (vector-push-extend elt newarr)))
          (build-array newarr)))

      (.func "reverse" ()
        (unless-array (build-array (fvector this))
          (setf (aobj-arr this) (nreverse (aobj-arr this)))
          this))
      (.func "sort" (compare)
        (unless-array (build-array (fvector this))
          (let ((func (if (eq compare :undefined)
                          (lambda (a b) (string< (to-string a) (to-string b)))
                          (let ((proc (proc compare)))
                            (lambda (a b) (funcall proc *env* a b))))))
            (sort (aobj-arr this) func)
            this)))

      (.func "indexOf" (elt (from 0))
        (unless-array -1
          (loop :with vec := (aobj-arr this) :for i :from (max 0 (to-integer from)) :below (length vec) :do
             (when (js=== (aref vec i) elt) (return i))
             :finally (return -1))))
      (.func "lastIndexOf" (elt (from :end))
        (unless-array -1
          (loop :with vec := (aobj-arr this) :with max := (1- (length vec))
             :for i :from (if (eq from :end) max (min max (to-integer from))) :downto 0 :do
             (when (js=== elt (aref vec i)) (return i))
             :finally (return -1))))

      (.func "every" (f (this* *env*))
        (unless-array t
          (loop :for elt :across (aobj-arr this) :for i :from 0 :do
             (unless (funcall (proc f) this* elt i this) (return nil))
             :finally (return t))))
      (.func "some" (f (this* *env*))
        (unless-array nil
          (loop :for elt :across (aobj-arr this) :for i :from 0 :do
             (when (funcall (proc f) this* elt i this) (return t))
             :finally (return nil))))

      (.func "filter" (f (this* *env*))
        (unless-array (build-array (empty-fvector 0))
          (let* ((vec (aobj-arr this))
                 (newvec (empty-fvector (length vec) 0)))
            (loop :for elt :across vec :for i :from 0 :do
               (when (funcall (proc f) this* elt i this) (vector-push-extend elt newvec)))
            (build-array newvec))))

      (.func "forEach" (f (this* *env*))
        (unless-array :undefined
          (loop :for elt :across (aobj-arr this) :for i :from 0 :do
             (funcall (proc f) this* elt i this))
          :undefined))
      (.func "map" (f (this* *env*))
        (unless-array (build-array (empty-fvector 0))
          (let* ((vec (aobj-arr this))
                 (newvec (empty-fvector (length vec))))
            (loop :for elt :across vec :for i :from 0 :do
               (setf (aref newvec i) (funcall (proc f) this* elt i this)))
            (build-array newvec))))))

  (.prototype :arguments
    (:slot-default :nodel)
    (.active-r "length" (argobj-length this))
    (.active-r "callee" (argobj-callee this)))

  (.constructor "String" (value)
    (if (eq this *env*)
        (to-string value)
        (progn (setf (vobj-value this) (to-string value)) this))
    (:prototype :string)
    (:make-new #'make-vobj)
    (:slot-default :noenum)
    (:properties
     (.func "fromCharCode" (code)
       (string (code-char (to-integer code)))))))

(add-to-lib *stdlib*
  (labels
      ((careful-substr (str from to)
         (let* ((len (length str))
                (from (clip-index (to-integer from) len)))
           (if (eq to :undefined)
               (subseq str from)
               (subseq str from (max from (clip-index (to-integer to) len))))))

       (really-string (val)
         (if (stringp val) val (and (vobj-p val) (stringp (vobj-value val)) (vobj-value val))))

       (string-replace (me pattern replacement)
         (let* ((parts ()) (pos 0) (me (to-string me))
                (replace
                 (if (fobj-p replacement)
                     (lambda (start end gstart gend)
                       (push (to-string (apply (fobj-proc replacement) *env* (subseq me start end)
                                               (loop :for gs :across gstart :for ge :across gend :for i :from 1
                                                  :collect (if start (subseq me gs ge) :undefined)
                                                  :when (eql i (length gstart)) :append (list start me))))
                             parts))
                     (let ((repl-str (to-string replacement)))
                       (if (ppcre:scan "\\\\\\d" repl-str)
                           (let ((tmpl (ppcre:split "\\\\(\\d)" repl-str :with-registers-p t)))
                             (loop :for cons :on (cdr tmpl) :by #'cddr :do
                                (setf (car cons) (1- (parse-integer (car cons)))))
                             (lambda (start end gstart gend)
                               (declare (ignore start end))
                               (loop :for piece :in tmpl :do
                                  (if (stringp piece)
                                      (when (> (length piece) 0) (push piece parts))
                                      (let ((start (aref gstart piece)))
                                        (when start (push (subseq me start (aref gend piece)) parts)))))))
                           (lambda (start end gstart gend)
                             (declare (ignore start end gstart gend))
                             (push repl-str parts)))))))
           (flet ((replace-occurrence (start end gstart gend)
                    (unless (eql start pos)
                      (push (subseq me pos start) parts))
                    (funcall replace start end gstart gend)
                    (setf pos end)))
             (cond ((not (reobj-p pattern))
                    (let ((pattern (to-string pattern))
                          (index (search (to-string pattern) me)))
                      (when index (replace-occurrence index (+ index (length pattern)) #.#() #.#()))))
                   ((not (reobj-global pattern))
                    (multiple-value-bind (start end gstart gend) (regexp-exec pattern me t)
                      (unless (eq start :null) (replace-occurrence start end gstart gend))))
                   (t (cached-set pattern "lastIndex" 0)
                      (loop
                         (multiple-value-bind (start end gstart gend) (regexp-exec pattern me t)
                           (when (eq start :null) (return))
                           (when (eql start end) (cached-set pattern "lastIndex" (1+ start)))
                           (replace-occurrence start end gstart gend)))))
             (if (or parts (> pos 0))
                 (progn (when (< pos (length me))
                          (push (subseq me pos) parts))
                        (apply #'concatenate 'string (nreverse parts)))
                 me)))))

    (.prototype :string
      (:slot-default :nodel)
      (.active-r "length" (let ((str (really-string this))) (if str (length str) 0)))

      (.func "toString" () (or (really-string this) (js-error :type-error "Incompatible type.")))
      (.func "valueOf" () (or (really-string this) (js-error :type-error "Incompatible type.")))

      (.func "charAt" (index)
        (let ((str (to-string this)) (idx (to-integer index)))
          (if (< -1 idx (length str)) (string (char str idx)) "")))
      (.func "charCodeAt" (index)
        (let ((str (to-string this)) (idx (to-integer index)))
          (if (< -1 idx (length str)) (char-code (char str idx)) (nan))))

      (.func "indexOf" (substr (start 0))
        (or (search (to-string substr) (to-string this) :start2 (to-integer start)) -1))
      (.func "lastIndexOf" (substr start)
        (let* ((str (to-string this))
               (start (if (eq start :undefined) (length str) (to-integer start))))
          (or (search (to-string substr) str :from-end t :end2 start))))

      (.func "substring" ((from 0) to)
        (careful-substr (to-string this) from to))
      (.func "substr" ((from 0) len)
        (careful-substr (to-string this) from
                        (if (eq len :undefined) len (+ (to-integer from) (to-integer len)))))
      (.func "slice" ((from 0) to)
        (let* ((from (to-integer from)) (str (to-string this))
               (to (if (eq to :undefined) (length str) (to-integer to))))
          (when (< from 0) (setf from (+ (length str) from)))
          (when (< to 0) (setf to (+ (length str) to)))
          (careful-substr str from to)))

      (.func "toUpperCase" ()
        (string-upcase (to-string this)))
      (.func "toLowerCase" ()
        (string-downcase (to-string this)))
      (.func "toLocaleUpperCase" ()
        (string-upcase (to-string this)))
      (.func "toLocaleLowerCase" ()
        (string-downcase (to-string this)))

      (.func "split" (delim)
        (let ((str (to-string this)))
          (if (reobj-p delim)
              (build-array (apply 'fvector (ppcre:split (reobj-scanner delim) str :sharedp t :omit-unmatched-p nil)))
              (let ((delim (to-string delim))
                    (arr (empty-fvector 0)))
                (if (equal delim "")
                    (loop :for ch :across str :do (vector-push-extend (string ch) arr))
                    (loop :for beg := 0 :then (+ pos (length delim))
                       :for pos := (search delim str :start2 beg) :do
                       (vector-push-extend (subseq str beg pos) arr)
                       (unless pos (return))))
                (build-array arr)))))

      (.func "concat" (&rest values)
        (apply #'concatenate 'string (cons (to-string this) (mapcar 'to-string values))))

      (.func "localeCompare" (that)
        (let ((a (to-string this)) (b (to-string that)))
          (cond ((string< a b) -1)
                ((string> a b) 1)
                (t 0))))

      (.func "match" (regexp)
        (unless (reobj-p regexp) (setf regexp (new-regexp regexp :undefined)))
        (let ((str (to-string this)))
          (if (reobj-global regexp)
              (let ((matches ()))
                (cached-set regexp "lastIndex" 0)
                (loop
                   (multiple-value-bind (start end) (regexp-exec regexp str t)
                     (when (eq start :null) (return))
                     (when (eql start end) (cached-set regexp "lastIndex" (1+ start)))
                     (push (subseq str start end) matches)))
                (build-array (apply 'fvector (nreverse matches))))
              (regexp-exec regexp str))))

      (.func "replace" (pattern replacement)
        (string-replace this pattern replacement))
      (.func "search" (pattern)
        (unless (reobj-p pattern) (setf pattern (new-regexp (to-string pattern) :undefined)))
        (values (regexp-exec pattern (to-string this) t t))))))

(add-to-lib *stdlib*
  (.constructor "Number" (value)
    (if (eq this *env*)
        (to-number value)
        (progn (setf (vobj-value this) (to-number value)) this))
    (:prototype :number)
    (:make-new #'make-vobj)
    (:slot-default :noenum)
    (:properties
     (.value "MAX_VALUE" most-positive-double-float)
     (.value "MIN_VALUE" least-positive-double-float)
     (.value "POSITIVE_INFINITY" (infinity))
     (.value "NEGATIVE_INFINITY" (-infinity))))

  (.prototype :number
    (:slot-default :nodel)
    (.func "toString" ((radix 10))
      (let ((num (typed-value-of this 'js-number)))
        (if (= radix 10)
            (to-string num)
            (let ((*print-radix* (to-integer radix))) (princ-to-string (floor num))))))
    (.func "valueOf" () (typed-value-of this 'js-number)))

  (.constructor "Boolean" (value)
    (if (eq this *env*)
        (to-boolean value)
        (progn (setf (vobj-value this) (to-boolean value)) this))
    (:prototype :boolean)
    (:make-new #'make-vobj))

  (.prototype :boolean
    (:slot-default :nodel)
    (.func "toString" () (if (typed-value-of this 'boolean) "true" "false"))
    (.func "valueOf" () (typed-value-of this 'boolean))))

(defun regexp-exec (re str &optional raw no-global)
  (let ((start 0) (str (to-string str)) (global (and (not no-global) (reobj-global re))))
    (when global
      (setf start (cached-lookup re "lastIndex"))
      (when (> -1 start (length str))
        (cached-set re "lastIndex" 0)
        (return-from regexp-exec :null)))
    (multiple-value-bind (mstart mend gstart gend)
        (ppcre:scan (reobj-scanner re) (to-string str) :start start)
      (when global
        (cached-set re "lastIndex" (if mend mend (1+ start))))
      (cond ((not mstart) :null)
            (raw (values mstart mend gstart gend))
            (t (let ((result (empty-fvector (1+ (length gstart)))))
                 (setf (aref result 0) (subseq str mstart mend))
                 (loop :for st :across gstart :for end :across gend :for i :from 1 :do
                    (when st (setf (aref result i) (subseq str st end))))
                 (build-array result)))))))
(defun new-regexp (pattern flags)
  (init-reobj (make-reobj (find-cls :regexp) nil nil nil) pattern flags))
(defun init-reobj (obj pattern flags)
  (let* ((flags (if (eq flags :undefined) "" (to-string flags)))
         (pattern (to-string pattern))
         (multiline (and (position #\m flags) t))
         (ignore-case (and (position #\i flags) t))
         (global (and (position #\g flags) t))
         (scanner (handler-case (ppcre:create-scanner pattern :case-insensitive-mode ignore-case
                                                      :multi-line-mode multiline)
                    (ppcre:ppcre-syntax-error (e)
                      (js-error :syntax-error (princ-to-string e))))))
    (unless (every (lambda (ch) (position ch "igm")) flags)
      (js-error :syntax-error "Invalid regular expression flags: ~a" flags))
    (setf (reobj-proc obj) (js-lambda (str) (regexp-exec obj str))
          (reobj-scanner obj) scanner
          (reobj-global obj) global)
    (cached-set obj "global" global)
    (cached-set obj "ignoreCase" ignore-case)
    (cached-set obj "multiline" multiline)
    (cached-set obj "source" pattern)
    (cached-set obj "lastIndex" 0)
    obj))

(add-to-lib *stdlib*
  (flet ((regexp-args (re)
           (values (cached-lookup re "source")
                   (format nil "~:[~;i~]~:[~;g~]~:[~;m~]" (cached-lookup re "ignoreCase")
                           (cached-lookup re "global") (cached-lookup re "multiline")))))

    (.constructor "RegExp" (pattern flags)
      (if (and (eq flags :undefined) (reobj-p pattern))
          (if (eq this *env*)
              pattern
              (multiple-value-bind (source flags) (regexp-args pattern)
                (init-reobj this source flags)))
          (if (eq this *env*)
              (new-regexp pattern flags)
              (init-reobj this pattern flags)))
      (:prototype :regexp)
      (:make-new #'make-reobj)
      (:slot-default :noenum)
      (:properties
       (.value "length" 2))) ;; Because the standard says so

    (.prototype :regexp
      (:slot-default :nodel)
      (.func "toString" ()
        (if (reobj-p this)
            (multiple-value-bind (source flags) (regexp-args this)
              (format nil "/~a/~a" source flags))
            (to-string this)))

      (.func "exec" (str)
        (if (reobj-p this) (regexp-exec this str) nil))
      (.func "compile" (expr flags)
        (when (reobj-p this) (init-reobj this expr flags))
        this)
      (.func "test" (str)
        (if (reobj-p this)
            (not (eq (regexp-exec this (to-string str) t) :null))
            nil)))))

#+js-dates
(add-to-lib *stdlib*
  (macrolet ((if-date ((val tvar &optional zonevar) &body then/else)
               (let ((v (gensym)))
                 `(let ((,v ,val))
                    (assert-date ,v)
                    (let (,@(when tvar `((,tvar (dobj-time ,v))))
                          ,@(when zonevar `((,zonevar (dobj-zone ,v)))))
                      (if ,v ,(car then/else) ,(if (cdr then/else) (second then/else) '(nan)))))))
             (date-setter (this unit val &key utc apply no-ret)
               (let ((v (gensym)) (tm (gensym)) (zn (gensym)))
                 `(let ((,v ,this))
                    (if-date (,v ,tm ,(if utc nil zn))
                      (,(if no-ret 'progn 'date-milliseconds)
                        (setf (dobj-time ,v)
                              (catch 'maybe-int
                                (local-time:adjust-timestamp ,tm
                                  (set ,unit ,(if apply (append apply `((maybe-int ,val))) `(maybe-int ,val)))
                                  (:timezone ,(if utc 'local-time:+utc-zone+ zn)))))))))))

    (labels
        ((maybe-int (x &optional (default 0))
           (if (eq x :none)
               default
               (let ((n (to-number x)))
                 (if (or (is-nan n) (eq n (infinity)) (eq n (-infinity)))
                     (throw 'maybe-int nil)
                     (truncate x)))))
         (assert-date (val)
           (unless (dobj-p val) (js-error :type-error "Not a Date object.")))
         (date-to-string (val flag &optional utc)
           (if-date (val time zone)
             (make-date-string time (if utc local-time:+utc-zone+ zone)  flag)
             "Invalid Date"))
         (make-date-string (timestamp zone type)
           (let ((format (ecase type
                           (:full local-time:+iso-8601-format+)
                           (:time '((:hour 2) #\: (:min 2) #\: (:sec 2) #\. (:usec 6) :gmt-offset-or-z))
                           (:date '((:year 4) #\- (:month 2) #\- (:day 2))))))
             (local-time:format-timestring nil timestamp :format format :timezone zone)))
         (date-milliseconds (timestamp)
           (let ((start-day #.(local-time:day-of (local-time:encode-timestamp 0 0 0 0 1 1 1970
                                                                              :timezone local-time:+utc-zone+))))

             (+ (* #.(* 1000 3600 24) (- (local-time:day-of timestamp) start-day))
                (* 1000 (local-time:sec-of timestamp))
                (mod (local-time:nsec-of timestamp) 1000000))))
         (date-from-milliseconds (ms)
           (let ((start-day #.(local-time:day-of (local-time:encode-timestamp 0 0 0 0 1 1 1970
                                                                              :timezone local-time:+utc-zone+))))
             (multiple-value-bind (days rest) (floor ms #.(* 1000 3600 24))
               (multiple-value-bind (secs ms) (floor rest 1000)
                 (make-instance 'local-time:timestamp :nsec (* ms 1000000) :sec secs :day (+ days start-day))))))
         (parse-date-string (str)
           (local-time:parse-rfc3339-timestring str :fail-on-error nil)))


      (.constructor "Date" ((year :none) (month :none) (date :none)
                            (hours :none) (minutes :none) (seconds :none) (ms :none))
        (if (eq this *env*)
            (make-date-string (local-time:now) local-time:*default-timezone* :full)
            (let ((time (cond ((eq year :none) (local-time:now))
                              ((eq month :none)
                               (let ((val (default-value year)))
                                 (if (stringp val)
                                     (parse-date-string val)
                                     (catch 'maybe-int (date-from-milliseconds (maybe-int val))))))
                              (t (catch 'maybe-int
                                   (local-time:encode-timestamp
                                    (* 1000000 (maybe-int ms)) (maybe-int seconds) (maybe-int minutes) (maybe-int hours)
                                    (maybe-int date 1) (1+ (maybe-int month)) (maybe-int year)))))))
              (setf (dobj-time this) time (dobj-zone this) local-time:*default-timezone*)
              this))
        (:prototype :date)
        (:make-new #'make-dobj)
        (:slot-default :noenum)
        (:properties
         (.value "length" 7)
         (.func "parse" (value)
           (let ((parsed (parse-date-string (to-string value))))
             (if parsed (date-milliseconds parsed) (nan))))
         (.func "UTC" ((year :none) (month :none) (date :none)
                       (hours :none) (minutes :none) (seconds :none) (ms :none))
           (date-milliseconds (local-time:encode-timestamp
                               (* 1000000 (maybe-int ms)) (maybe-int seconds) (maybe-int minutes) (maybe-int hours)
                               (maybe-int date 1) (1+ (maybe-int month 0)) (maybe-int year 1970)
                               :timezone local-time:+utc-zone+)))))

      (.prototype :date
        (:slot-default :nodel)
        (.func "toString" () (date-to-string this :full))
        (.func "toUTCString" () (date-to-string this :full t))
        (.func "toDateString" () (date-to-string this :date))
        (.func "toTimeString" () (date-to-string this :time))
        (.func "toLocaleString" () (date-to-string this :full))
        (.func "toLocaleDateString" () (date-to-string this :date))
        (.func "toLocaleTimeString" () (date-to-string this :time))
        (.func "valueOf" ()
          (if-date (this time) (date-milliseconds time)))
        (.func "getTime" ()
          (if-date (this time) (date-milliseconds time)))

        (.func "getFullYear" ()
          (if-date (this time zone) (local-time:timestamp-year time :timezone zone)))
        (.func "getUTCFullYear" ()
          (if-date (this time) (local-time:timestamp-year time :timezone local-time:+utc-zone+)))
        (.func "getYear" ()
          (if-date (this time zone) (mod (local-time:timestamp-year time :timezone zone) 100)))
        (.func "getMonth" ()
          (if-date (this time zone) (1- (local-time:timestamp-month time :timezone zone))))
        (.func "getUTCMonth" ()
          (if-date (this time) (1- (local-time:timestamp-month time :timezone local-time:+utc-zone+))))
        (.func "getDate" ()
          (if-date (this time zone) (local-time:timestamp-day time :timezone zone)))
        (.func "getUTCDate" ()
          (if-date (this time) (local-time:timestamp-day time :timezone local-time:+utc-zone+)))

        (.func "getDay" ()
          (if-date (this time zone) (local-time:timestamp-day-of-week time :timezone zone)))
        (.func "getUTCDay" ()
          (if-date (this time) (local-time:timestamp-day-of-week time :timezone local-time:+utc-zone+)))

        (.func "getHours" ()
          (if-date (this time zone) (local-time:timestamp-hour time :timezone zone)))
        (.func "getUTCHours" ()
          (if-date (this time) (local-time:timestamp-hour time :timezone local-time:+utc-zone+)))
        (.func "getMinutes" ()
          (if-date (this time zone) (local-time:timestamp-minute time :timezone zone)))
        (.func "getUTCMinutes" ()
          (if-date (this time) (local-time:timestamp-minute time :timezone local-time:+utc-zone+)))
        (.func "getSeconds" ()
          (if-date (this time zone) (local-time:timestamp-second time :timezone zone)))
        (.func "getUTCSeconds" ()
          (if-date (this time) (local-time:timestamp-second time :timezone local-time:+utc-zone+)))
        (.func "getMilliseconds" ()
          (if-date (this time) (local-time:timestamp-millisecond time)))
        (.func "getUTCMilliseconds" ()
          (if-date (this time) (local-time:timestamp-millisecond time)))
        
        (.func "getTimezoneOffset" ()
          (if-date (this time zone)
            (mod (local-time::%guess-offset (local-time:day-of time) (local-time::sec-of time) zone) 60)))

        (.func "setTime" (date)
          (assert-date this)
          (let ((time (setf (dobj-time this) (if-date (date time) time nil))))
            (if time (date-milliseconds time) (nan))))

        (.func "setFullYear" (year (month :none) (date :none))
          (unless (eq date :none) (date-setter this :day-of-month date :no-ret t))
          (unless (eq month :none) (date-setter this :month month :apply (1+) :no-ret t))
          (date-setter this :year year))
        (.func "setUTCFullYear" (year (month :none) (date :none))
          (unless (eq date :none) (date-setter this :day-of-month date :no-ret t :utc t))
          (unless (eq month :none) (date-setter this :month month :apply (1+) :no-ret t :utc t))
          (date-setter this :year year :utc t))
        (.func "setMonth" (month (date :none))
          (unless (eq date :none) (date-setter this :day-of-month date :no-ret t))
          (date-setter this :month month :apply (1+)))
        (.func "setUTCMonth" (month (date :none))
          (unless (eq date :none) (date-setter this :day-of-month date :utc t :no-ret t))
          (date-setter this :month month :apply (1+) :utc t))
        (.func "setDate" (date) (date-setter this :day-of-month date))
        (.func "setUTCDate" (date) (date-setter this :day-of-month date :utc t))
        (.func "setHours" (hour) (date-setter this :hours hour))
        (.func "setUTCHours" (hour) (date-setter this :hours hour :utc t))
        (.func "setMinutes" (min) (date-setter this :minute min))
        (.func "setUTCMinutes" (min) (date-setter this :minute min :utc t))
        (.func "setSeconds" (sec) (date-setter this :sec sec))
        (.func "setUTCSeconds" (sec) (date-setter this :sec sec :utc t))
        (.func "setMilliseconds" (ms) (date-setter this :nsec ms :apply (* 1000000)))
        (.func "setUTCMilliseconds" (ms) (date-setter this :nsec ms :apply (* 1000000) :utc t))))))

(add-to-lib *stdlib*
  (.constructor "Error" (message)
    (let ((this (if (eq this *env*) (js-obj :error) this)))
      (unless (eq message :undefined)
        (cached-set this "message" message))
      this)
    (:prototype :error))

  (.prototype :error
    (:slot-default :nodel)
    (.value "name" "Error")
    (.value "message" "Error")
    (.func "toString" ()
      (concatenate 'string "Error: " (to-string (cached-lookup this "message")))))

  (macrolet ((deferror (name id)
               `(progn (.constructor ,name (message)
                         (let ((this (if (eq this *env*) (js-obj :error) this)))
                           (unless (eq message :undefined)
                             (cached-set this "message" message))
                           this)
                         (:prototype ,id))
                       (.prototype ,id
                         (:parent :error)
                         (:slot-default :nodel)
                         (.func "toString" ()
                           (concatenate 'string ,(format nil "~a: " name)
                                        (to-string (cached-lookup this "message"))))))))
    (deferror "SyntaxError" :syntax-error)
    (deferror "ReferenceError" :reference-error)
    (deferror "TypeError" :type-error)
    (deferror "URIError" :uri-error)
    (deferror "EvalError" :eval-error)
    (deferror "RangeError" :range-error)))

(add-to-lib *stdlib*
  (macrolet ((with-overflow (&body body)
                            `(handler-case (progn ,@body)
                               (floating-point-overflow () (infinity)) ;; TODO -infinity?
                               (floating-point-underflow () 0d0)))
             (math-case (var &body cases)
               (flet ((find-case (id)
                        (or (cdr (assoc id cases)) '((nan)))))
                 `(let ((,var (to-number ,var)))
                    (with-overflow
                      (cond ((is-nan ,var) ,@(find-case :NaN))
                            ((eq ,var (infinity)) ,@(find-case :Inf))
                            ((eq ,var (-infinity)) ,@(find-case :-Inf))
                            (t ,@(find-case t)))))))
             (compare-num (a b gt lt cmp)
               `(let ((ls ,a) (rs ,b))
                  (cond ((or (is-nan ls) (is-nan rs)) (nan))
                        ((or (eq ls ,gt) (eq rs ,gt)) ,gt)
                        ((eq ls ,lt) rs)
                        ((eq rs ,lt) ls)
                        (t (,cmp ls rs))))))

    (.object "Math"
      (:slot-default :noenum)

      (.func "toString" () "[object Math]")

      (.value "E" (exp 1))
      (.value "LN2" (log 2))
      (.value "LN10" (log 10))
      (.value "LOG2E" (log (exp 1) 2))
      (.value "LOG10E" (log (exp 1) 10))
      (.value "SQRT1_2" (sqrt .5))
      (.value "SQRT1_2" (sqrt 2))
      (.value "PI" pi)

      (.func "abs" (arg)
        (math-case arg (:-Inf (infinity)) (:Inf (infinity)) (t (abs arg))))

      (.func "cos" (arg)
        (math-case arg (t (cos arg))))
      (.func "sin" (arg)
        (math-case arg (t (sin arg))))
      (.func "tan" (arg)
        (math-case arg (t (tan arg))))

      (.func "acos" (arg)
        (math-case arg (t (let ((res (acos arg))) (if (realp res) res (nan))))))
      (.func "asin" (arg)
        (math-case arg (t (let ((res (asin arg))) (if (realp res) res (nan))))))

      (flet ((my-atan (arg)
               (math-case arg (:-Inf (- (/ pi 2))) (:Inf (/ pi 2)) (t (atan arg)))))
        (.func "atan" (arg) (my-atan arg))
        (.func "atan2" (x y) (my-atan (js/ x y))))

      (.func "ceil" (arg)
        (math-case arg (:-Inf (-infinity)) (:Inf (infinity)) (t (ceiling arg))))
      (.func "floor" (arg)
        (math-case arg (:-Inf (-infinity)) (:Inf (infinity)) (t (floor arg))))
      (.func "round" (arg)
        (math-case arg (:-Inf (-infinity)) (:Inf (infinity)) (t (round arg))))

      (.func "exp" (arg)
        (math-case arg (:-Inf 0) (:Inf (infinity)) (t (exp arg))))
      (.func "log" (arg)
        (math-case arg
          (:Inf (infinity))
          (t (cond ((zerop arg) (-infinity))
                   ((minusp arg) (nan))
                   (t (log arg))))))
      (.func "sqrt" (arg)
        (math-case arg (:Inf (infinity))
                   (t (let ((res (sqrt arg))) (if (realp res) res (nan))))))
      (.func "pow" (base exp)
        (let ((base (to-number base)) (exp (to-number exp)))
          (cond ((or (is-nan base) (is-nan exp)) (nan))
                ((eq exp (-infinity)) (nan))
                ((and (realp exp) (zerop exp)) 1)
                ((or (eq base (infinity)) (eq exp (infinity))) (infinity))
                ((eq base (-infinity)) (-infinity))
                (t (coerce (with-overflow (expt base exp)) 'double-float)))))

      (.func "max" (&rest args)
        (let ((cur (-infinity)))
          (dolist (arg args)
            (setf cur (compare-num cur (to-number arg) (infinity) (-infinity) max)))
          cur))
      (.func "min" (&rest args)
        (let ((cur (infinity)))
          (dolist (arg args)
            (setf cur (compare-num cur (to-number arg) (-infinity) (infinity) min)))
          cur))

      (.func "random" ()
        (random 1.0)))))

(add-to-lib *stdlib*
  (.object "JSON"
    (:slot-default :noenum)
    (.func "parse" (string)
      (parse-json (to-string string)))
    (.func "stringify" (string replacer)
      (stringify-json string replacer))))

(defparameter *printlib* (empty-lib))

(add-to-lib *printlib*
  (.func "print" (val)
    (format t "~a~%" (to-string val))))
