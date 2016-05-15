;;;; Copyright (c) 2011-2015 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; Builtin functions for dealing with numbers.

(in-package :sys.c)

(defbuiltin system:fixnump (object) ()
  (load-in-reg :r8 object t)
  (emit `(sys.lap-x86:test8 :r8l ,sys.int::+fixnum-tag-mask+))
  (predicate-result :z))

(define-tag-type-predicate floatp sys.int::+tag-single-float+)

;;; Bitwise operators.

(defmacro define-two-arg-bitwise-op (name instruction support-function)
  `(defbuiltin ,name (x y) ()
     (let ((helper (gensym))
           (resume (gensym)))
       ;; Constants on the left hand side.
       (when (constant-type-p y 'fixnum)
         (rotatef x y))
       ;; Call out to the support function for non-fixnums.
       (emit-trailer (helper)
         (when (constant-type-p x 'fixnum)
           (load-constant :r9 (second x)))
         (call-support-function ',support-function 2)
         (emit `(sys.lap-x86:jmp ,resume)))
       (cond ((constant-type-p x 'fixnum)
              (load-in-r8 y t)
              (smash-r8)
              (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
                    `(sys.lap-x86:jnz ,helper))
              ;; Small integers can be encoded directly into the instruction.
              (if (small-fixnum-p (second x))
                  (emit `(,',instruction :r8 ,(fixnum-to-raw (second x))))
                  (emit `(sys.lap-x86:mov64 :rax ,(fixnum-to-raw (second x)))
                        `(,',instruction :r8 :rax)))
              (emit resume)
              (setf *r8-value* (list (gensym))))
             (t (load-in-reg :r9 y t)
                (load-in-reg :r8 x t)
                (smash-r8)
                (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
                      `(sys.lap-x86:jnz ,helper)
                      `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
                      `(sys.lap-x86:jnz ,helper)
                      `(,',instruction :r8 :r9)
                      resume)
                (setf *r8-value* (list (gensym))))))))

(define-two-arg-bitwise-op sys.int::binary-logior sys.lap-x86:or64 sys.int::generic-logior)
(define-two-arg-bitwise-op sys.int::binary-logxor sys.lap-x86:xor64 sys.int::generic-logxor)
(define-two-arg-bitwise-op sys.int::binary-logand sys.lap-x86:and64 sys.int::generic-logand)

(defbuiltin lognot (integer) ()
  (let ((not-fixnum (gensym "lognot-other"))
        (resume (gensym "lognot-resume")))
    (emit-trailer (not-fixnum)
      (call-support-function 'sys.int::generic-lognot 1)
      (emit `(sys.lap-x86:jmp ,resume)))
    (load-in-reg :r8 integer t)
    (smash-r8)
    (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,not-fixnum)
          `(sys.lap-x86:xor64 :r8 ,(- (ash 1 sys.int::+n-fixnum-bits+)))
          resume)
    (setf *r8-value* (list (gensym)))))

(defbuiltin mezzano.runtime::%fixnum-left-shift (integer count) ()
  ;; INTEGER and COUNT must both be fixnums.
  (load-in-reg :r8 integer t)
  (cond ((constant-type-p count 'fixnum)
         (let ((count-value (second count))
               (resume (gensym "ash-resume"))
               (ovfl (gensym))
               (loop-head (gensym)))
           ;; Perform the shift one bit at a time so that overflow can be checked for.
           (emit-trailer (ovfl)
             ;; Shift count in R9, overflowed value in R8, carry bit set to last
             ;; bit shifted out.
             ;; Undo the last shift, then call into the helper function.
             (emit `(sys.lap-x86:rcr64 :r8 1))
             (call-support-function 'mezzano.runtime::left-shift 2)
             (emit `(sys.lap-x86:jmp ,resume)))
           (load-constant :r9 count-value)
           (smash-r8)
           (emit loop-head)
           (emit `(sys.lap-x86:shl64 :r8 1)
                 `(sys.lap-x86:jo ,ovfl)
                 `(sys.lap-x86:sub64 :r9 ,(fixnum-to-raw 1))
                 `(sys.lap-x86:jnz ,loop-head))
           (emit resume)))
        (t (let ((shift-left (gensym))
                 (ovfl (gensym))
                 (really-done (gensym))
                 (count-save (allocate-control-stack-slots 1)))
             (emit-trailer (ovfl)
               (emit
                ;; Stash the count.
                `(sys.lap-x86:mov64 ,(control-stack-slot-ea count-save) :rcx)
                ;; Recover carry.
                `(sys.lap-x86:rcr64 :rax 1)
                ;; Drop the remaining fixnum tag bits.
                ;(when (> sys.int::+n-fixnum-bits+ 1)
                ;  (emit `(sys.lap-x86:sar64 :rax ,(1- sys.int::+n-fixnum-bits+))))
                ;; Turn it into a bignum.
                `(sys.lap-x86:mov64 :r13 (:function sys.int::%%make-bignum-64-rax))
                `(sys.lap-x86:call ,(object-ea :r13 :slot sys.int::+fref-entry-point+))
                ;; Fall into the bignum helper.
                `(sys.lap-x86:mov64 :rcx ,(control-stack-slot-ea count-save))
                `(sys.lap-x86:lea64 :r9 ((:rcx ,(ash 1 sys.int::+n-fixnum-bits+)) ,(fixnum-to-raw -1))))
               (call-support-function 'mezzano.runtime::left-shift 2)
               (emit
                `(sys.lap-x86:jmp ,really-done)))
             (load-in-reg :r9 count t)
             (smash-r8)
             (emit `(sys.lap-x86:mov64 :rax :r8))
             (emit `(sys.lap-x86:mov64 :rcx :r9)
                   ;; Left shift.
                   ;; Perform the shift one bit at a time so that overflow can be checked for.
                   `(sys.lap-x86:sar64 :rcx ,sys.int::+n-fixnum-bits+)
                   shift-left
                   `(sys.lap-x86:shl64 :rax 1)
                   `(sys.lap-x86:jo ,ovfl)
                   `(sys.lap-x86:sub64 :rcx 1)
                   `(sys.lap-x86:jnz ,shift-left)
                   `(sys.lap-x86:mov64 :r8 :rax)
                   really-done))))
  (setf *r8-value* (list (gensym))))

(defbuiltin mezzano.runtime::%fixnum-right-shift (integer count) ()
  ;; INTEGER and COUNT must both be fixnums.
  (load-in-reg :r8 integer t)
  (emit `(sys.lap-x86:mov64 :rax :r8))
  (cond ((constant-type-p count 'fixnum)
         (let ((count-value (second count)))
           (smash-r8)
           (cond ((>= count-value (- 64 sys.int::+n-fixnum-bits+))
                  ;; All bits shifted out.
                  (emit `(sys.lap-x86:cqo)
                        `(sys.lap-x86:and64 :rdx ,(- (ash 1 sys.int::+n-fixnum-bits+)))
                        `(sys.lap-x86:mov64 :r8 :rdx)))
                 (t (emit `(sys.lap-x86:sar64 :rax ,count-value)
                          `(sys.lap-x86:and64 :rax ,(- (ash 1 sys.int::+n-fixnum-bits+)))
                          `(sys.lap-x86:mov64 :r8 :rax))))))
        (t
         ;; Shift right by arbitrary count.
         (let ((done-label (gensym))
               (sign-extend (gensym)))
           (load-in-reg :r9 count t)
           (smash-r8)
           (emit `(sys.lap-x86:mov64 :rcx :r9)
                 ;; x86 masks the shift count to 6 bits, test if all the bits were shifted out.
                 `(sys.lap-x86:cmp64 :rcx ,(fixnum-to-raw 64))
                 `(sys.lap-x86:jae ,sign-extend)
                 `(sys.lap-x86:sar64 :rcx ,sys.int::+n-fixnum-bits+)
                 `(sys.lap-x86:sar64 :rax :cl)
                 `(sys.lap-x86:and64 :rax ,(- (ash 1 sys.int::+n-fixnum-bits+)))
                 `(sys.lap-x86:jmp ,done-label)
                 sign-extend
                 `(sys.lap-x86:cqo)
                 `(sys.lap-x86:and64 :rdx ,(- (ash 1 sys.int::+n-fixnum-bits+)))
                 `(sys.lap-x86:mov64 :rax :rdx)
                 done-label
                 `(sys.lap-x86:mov64 :r8 :rax)))))
  (setf *r8-value* (list (gensym))))

;;; Arithmetic.

(defbuiltin sys.int::binary-+ (x y) ()
  (let ((ovfl (gensym "+ovfl"))
        (resume (gensym "+resume"))
        (full-add (gensym "+full")))
    (when (constant-type-p y 'fixnum)
      (rotatef x y))
    (emit-trailer (ovfl)
      ;; Recover the full value using the carry bit.
      (emit `(sys.lap-x86:mov64 :rax :r8)
            `(sys.lap-x86:rcr64 :rax 1))
      ;; Drop the remaining fixnum tag bits.
      ;(when (> sys.int::+n-fixnum-bits+ 1)
      ;  (emit `(sys.lap-x86:sar64 :rax ,(1- sys.int::+n-fixnum-bits+))))
      ;; Call assembly helper function.
      (emit `(sys.lap-x86:mov64 :r13 (:function sys.int::%%make-bignum-64-rax))
            `(sys.lap-x86:call ,(object-ea :r13 :slot sys.int::+fref-entry-point+))
            `(sys.lap-x86:jmp ,resume)))
    (emit-trailer (full-add)
      (when (constant-type-p x 'fixnum)
        (load-constant :r9 (second x)))
      (call-support-function 'sys.int::generic-+ 2)
      (emit `(sys.lap-x86:jmp ,resume)))
    (cond ((constant-type-p x 'fixnum)
           (load-in-r8 y t)
           (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
                 `(sys.lap-x86:jnz ,full-add))
           (smash-r8)
           ;; Small integers can be encoded directly into the instruction.
           (if (small-fixnum-p (second x))
               (emit `(sys.lap-x86:add64 :r8 ,(fixnum-to-raw (second x))))
               (emit `(sys.lap-x86:mov64 :rax ,(fixnum-to-raw (second x)))
                     `(sys.lap-x86:add64 :r8 :rax))))
          (t (load-in-reg :r9 y t)
             (load-in-reg :r8 x t)
             (emit `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
                   `(sys.lap-x86:jnz ,full-add)
                   `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
                   `(sys.lap-x86:jnz ,full-add))
             (smash-r8)
             (emit `(sys.lap-x86:add64 :r8 :r9))))
    (emit `(sys.lap-x86:jo ,ovfl)
          resume)
    (setf *r8-value* (list (gensym)))))

(defbuiltin sys.int::binary-- (x y) ()
  (let ((ovfl (gensym "-ovfl"))
        (resume (gensym "-resume"))
        (full-sub (gensym "-full")))
    (emit-trailer (ovfl)
      ;; Recover the full value.
      (emit `(sys.lap-x86:cmc)
            `(sys.lap-x86:mov64 :rax :r8)
            `(sys.lap-x86:rcr64 :rax 1))
      ;; Drop the remaining fixnum tag bits.
      ;(when (> sys.int::+n-fixnum-bits+ 1)
      ;  (emit `(sys.lap-x86:sar64 :rax ,(1- sys.int::+n-fixnum-bits+))))
      ;; Call assembly helper function.
      (emit `(sys.lap-x86:mov64 :r13 (:function sys.int::%%make-bignum-64-rax))
            `(sys.lap-x86:call ,(object-ea :r13 :slot sys.int::+fref-entry-point+))
            `(sys.lap-x86:jmp ,resume)))
    (emit-trailer (full-sub)
      (call-support-function 'sys.int::generic-- 2)
      (emit `(sys.lap-x86:jmp ,resume)))
    (load-in-reg :r8 x t)
    (load-in-reg :r9 y t)
    (smash-r8)
    (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-sub)
          `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-sub)
          `(sys.lap-x86:sub64 :r8 :r9)
          `(sys.lap-x86:jo ,ovfl)
          resume)
    (setf *r8-value* (list (gensym)))))

(defbuiltin sys.int::binary-* (x y) ()
  (let ((ovfl (gensym "*ovfl"))
        (resume (gensym "*resume"))
        (full-mul (gensym "*full"))
        (small-bignum (gensym "*small-result")))
    (emit-trailer (ovfl)
      ;; 128-bit result in rdx:rax.
      ;; Unbox the result.
      (emit `(sys.lap-x86:shrd64 :rax :rdx ,sys.int::+n-fixnum-bits+)
            `(sys.lap-x86:sar64 :rdx ,sys.int::+n-fixnum-bits+)
            ;; Check if the result will fit in 64 bits.
            ;; Save the high bits.
            `(sys.lap-x86:mov64 :rcx :rdx)
            `(sys.lap-x86:cqo)
            `(sys.lap-x86:cmp64 :rcx :rdx)
            `(sys.lap-x86:je ,small-bignum)
            ;; Nope.
            `(sys.lap-x86:mov64 :rdx :rcx)
            `(sys.lap-x86:mov64 :r13 (:function sys.int::%%make-bignum-128-rdx-rax))
            `(sys.lap-x86:call ,(object-ea :r13 :slot sys.int::+fref-entry-point+))
            `(sys.lap-x86:jmp ,resume)
            small-bignum
            ;; Yup.
            `(sys.lap-x86:mov64 :r13 (:function sys.int::%%make-bignum-64-rax))
            `(sys.lap-x86:call ,(object-ea :r13 :slot sys.int::+fref-entry-point+))
            `(sys.lap-x86:jmp ,resume)))
    (emit-trailer (full-mul)
      (call-support-function 'sys.int::generic-* 2)
      (emit `(sys.lap-x86:jmp ,resume)))
    (load-in-reg :r9 y t)
    (load-in-reg :r8 x t)
    (smash-r8)
    (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-mul)
          `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-mul)
          `(sys.lap-x86:mov64 :rax :r8)
          ;; Convert RAX to raw integer, leaving R9 as a fixnum.
          ;; This will cause the result to be a fixnum.
          `(sys.lap-x86:sar64 :rax ,sys.int::+n-fixnum-bits+)
          `(sys.lap-x86:imul64 :r9)
          `(sys.lap-x86:jo ,ovfl)
          ;; R9 was not converted to a raw integer, so the result
          ;; was automatically converted to a fixnum.
          `(sys.lap-x86:mov64 :r8 :rax)
          resume)
    (setf *r8-value* (list (gensym)))))

(defbuiltin rem (number divisor) ()
  (let ((full-rem (gensym "full-rem"))
        (resume (gensym "resume-rem")))
    (emit-trailer (full-rem)
      (call-support-function 'sys.int::generic-rem 2)
      (emit `(sys.lap-x86:jmp ,resume)))
    (load-in-reg :r9 divisor t)
    (load-in-reg :r8 number t)
    (smash-r8)
    (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-rem)
          `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-rem)
          ;; Bail out to the full REM on /0.
          `(sys.lap-x86:test64 :r9 :r9)
          `(sys.lap-x86:jz ,full-rem)
          ;; Don't check for REM -1, don't care about the quotient.
          `(sys.lap-x86:mov64 :rax :r8)
          `(sys.lap-x86:cqo)
          `(sys.lap-x86:idiv64 :r9)
          ;; :rdx holds the remainder as a fixnum.
          `(sys.lap-x86:mov64 :r8 :rdx)
          resume)
    (setf *r8-value* (list (gensym)))))

(defbuiltin sys.int::%truncate (number divisor) ()
  (let ((full-truncate (gensym "full-truncate"))
        (resume (gensym "resume-truncate")))
    (emit-trailer (full-truncate)
      (call-support-function 'sys.int::generic-truncate 2
                             (not (member *for-value* '(:multiple :tail))))
      (emit `(sys.lap-x86:jmp ,resume)))
    (load-in-reg :r9 divisor t)
    (load-in-reg :r8 number t)
    (smash-r8)
    (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-truncate)
          `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
          `(sys.lap-x86:jnz ,full-truncate)
          ;; Bail out to the full truncate when /0 or /-1.
          `(sys.lap-x86:test64 :r9 :r9)
          `(sys.lap-x86:jz ,full-truncate)
          `(sys.lap-x86:cmp64 :r9 ,(- (ash 1 sys.int::+n-fixnum-bits+)))
          `(sys.lap-x86:je ,full-truncate)
          `(sys.lap-x86:mov64 :rax :r8)
          `(sys.lap-x86:cqo)
          `(sys.lap-x86:idiv64 :r9)
          ;; :rax holds the dividend as a integer.
          ;; :rdx holds the remainder as a fixnum.
          `(sys.lap-x86:shl64 :rax ,sys.int::+n-fixnum-bits+)
          `(sys.lap-x86:mov64 :r8 :rax))
    (prog1 (cond ((member *for-value* '(:multiple :tail))
                  (emit `(sys.lap-x86:mov64 :r9 :rdx))
                  (load-constant :rcx 2)
                  :multiple)
                 (t (setf *r8-value* (list (gensym)))))
      (emit resume))))

;;; Comparisons.

(defmacro define-conditional-builtin (name generic-name conditional)
  `(defbuiltin ,name (x y) ()
     (let ((generic (gensym))
           (resume (gensym)))
       (emit-trailer (generic)
         (call-support-function ',generic-name 2)
         (emit `(sys.lap-x86:jmp ,resume)))
       (load-in-reg :r9 y t)
       (load-in-reg :r8 x t)
       (smash-r8)
       (emit `(sys.lap-x86:test64 :r8 ,sys.int::+fixnum-tag-mask+)
             `(sys.lap-x86:jnz ,generic)
             `(sys.lap-x86:test64 :r9 ,sys.int::+fixnum-tag-mask+)
             `(sys.lap-x86:jnz ,generic)
             `(sys.lap-x86:cmp64 :r8 :r9)
             `(sys.lap-x86:mov64 :r8 nil)
             `(sys.lap-x86:mov64 :r9 t)
             `(,',(predicate-instruction-cmov-instruction
                   (predicate-info conditional)) :r8 :r9)
             resume)
       (setf *r8-value* (list (gensym))))))

(define-conditional-builtin sys.int::binary-< sys.int::generic-< :l)
(define-conditional-builtin sys.int::binary->= sys.int::generic->= :ge)
(define-conditional-builtin sys.int::binary-> sys.int::generic-> :g)
(define-conditional-builtin sys.int::binary-<= sys.int::generic-<= :le)
(define-conditional-builtin sys.int::binary-= sys.int::generic-= :e)
