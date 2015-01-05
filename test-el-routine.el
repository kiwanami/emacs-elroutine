;;; test code for el-routine.el

;; Copyright (C) 2014  SAKURAI Masashi
;; Author: SAKURAI Masashi <m.sakurai at kiwanami.net>

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; How to run this test ?
;; $ emacs -L . -L $HOME/.emacs.d/elisp -batch -l deferred -l concurrent -l el-routine -l test-el-routine -f elcc:test-all

(require 'el-routine)


;;; async test framework

(defmacro elcc:debug (d msg &rest args)
  "Wait for the deferred task and display the result on the minibuffer.
This function is for debugging of the single test function."
  `(deferred:nextc ,d
     (lambda (x) (funcall 'message ,msg ,@args) x)))


;; (elcc:debug (elcc:test-signal2) "Signal2 : %s" x)

(defvar elcc:test-finished-flag nil)
(defvar elcc:test-fails 0)

(defun elcc:run-tests (test-functions &optional timeout-msec)
  "Run the given test functions, wait for the all test finishing
and pop up the results buffer.
TIMEOUT-MSEC is waiting time for async tests. 5000 is default
value. "
  (setq elcc:test-finished-flag nil)
  (setq elcc:test-fails 0)
  (deferred:$
    (deferred:parallel
      (loop for i in test-functions
            collect (cons i (deferred:timeout (or timeout-msec 5000)
                              "timeout" (funcall i)))))
    (deferred:nextc it
      (lambda (results)
        (pop-to-buffer
         (with-current-buffer (get-buffer-create "*elcc:test*")
           (erase-buffer)
           (loop for i in results
                 for name = (car i)
                 for result = (cdr i)
                 with fails = 0
                 do (insert (format "%s : %s\n" name 
                                    (if (eq t result) "OK" 
                                      (format "FAIL > %s" result))))
                 (unless (eq t result) (incf fails))
                 finally 
                 (goto-char (point-min))
                 (insert (format "Test Finished : %s\nTests Fails: %s / %s\n" 
                                 (format-time-string   "%Y/%m/%d %H:%M:%S" (current-time))
                                 fails (length results)))
                 (setq elcc:test-fails fails))
           (message (buffer-string))
           (current-buffer)))
        (setq elcc:test-finished-flag t))))

  (while (null elcc:test-finished-flag)
    (sleep-for 0 100) (sit-for 0 100))
  (when (and noninteractive
             (> elcc:test-fails 0))
    (error "Test failed")))



;;; tests for worker module


(defun elcc:test-worker-basic ()
  (lexical-let*
      ((trace-syms '(init))
       (ctx (elcc:worker-create-context
             1 
             (lambda (worker) 
               (push 'pre-create trace-syms)
               (deferred:next 
                 (lambda ()
                   (push 'post-create trace-syms))))
              (lambda () )
              (lambda (worker task) 
                (push 'pass trace-syms)
                (funcall task)
                (deferred:next 
                  (lambda () 
                    (push 'pass-end trace-syms))))
              )))
    (push (lambda () 
            (push 'ondone trace-syms))
          (elcc:worker-context-ondone-hook ctx))
    (deferred:$
      (elcc:worker-exec-task
       ctx (lambda () (push 'exec-task trace-syms)))
      (deferred:nextc it
        (lambda () 
          (elcc:worker-wait-all ctx)))
      (deferred:nextc it
        (lambda () 
          (setq trace-syms (reverse trace-syms))
          (or (equal
               '(init pre-create post-create pass exec-task pass-end ondone)
               trace-syms) trace-syms))))))

;; (elcc:debug (elcc:test-worker-basic) "basic : %s" x)

(defun elcc:test-worker-basic-single-2task ()
  (lexical-let*
      ((trace-syms '(init))
       (ctx (elcc:worker-create-context
             1 
             (lambda (worker) 
               (push 'pre-create trace-syms)
               (deferred:next 
                 (lambda ()
                   (push 'post-create trace-syms))))
              (lambda () )
              (lambda (worker task) 
                (push 'pass trace-syms)
                (funcall task)
                (deferred:next 
                  (lambda () 
                    (push 'pass-end trace-syms))))
              )))
    (push (lambda () 
            (push 'ondone trace-syms))
          (elcc:worker-context-ondone-hook ctx))
    (deferred:$
      (deferred:parallel 
        (elcc:worker-exec-task ctx (lambda () (push 'exec-task1 trace-syms)))
        (elcc:worker-exec-task ctx (lambda () (push 'exec-task2 trace-syms))))
      (deferred:nextc it
        (lambda () 
          (elcc:worker-wait-all ctx)))
      (deferred:nextc it
        (lambda () 
          (setq trace-syms (reverse trace-syms))
          (or (equal
               '(init pre-create post-create pass exec-task1 pass-end ondone pass exec-task2 pass-end ondone)
               trace-syms) trace-syms))))))

;; (elcc:debug (elcc:test-worker-basic-single-2task) "single-2task : %s" x)


(defun elcc:test-worker-basic-delete ()
  (lexical-let*
      ((trace-syms '(init))
       (ctx (elcc:worker-create-context
             1 
             (lambda (worker) 
               (push 'pre-create trace-syms)
               (deferred:next 
                 (lambda ()
                   (push 'post-create trace-syms))))
              (lambda (w) 
                (push 'delete trace-syms)
                (deferred:succeed))
              (lambda (worker task) 
                (push 'pass trace-syms)
                (funcall task)
                (deferred:next 
                  (lambda () 
                    (push 'pass-end trace-syms))))
              )))
    (push (lambda () 
            (push 'ondone trace-syms))
          (elcc:worker-context-ondone-hook ctx))
    (deferred:$
      (elcc:worker-exec-task ctx (lambda () (push 'exec-task trace-syms)))
      (deferred:nextc it
        (lambda () (elcc:worker-wait-all ctx)))
      (deferred:nextc it
        (lambda () (elcc:worker-context-delete-worker-instance ctx (car (elcc:worker-context-workers ctx)))))
      (deferred:nextc it
        (lambda () 
          (push (length (elcc:worker-context-workers ctx)) trace-syms)
          (setq trace-syms (reverse trace-syms))
          (or (equal
               '(init pre-create post-create pass exec-task pass-end ondone delete 0)
               trace-syms) trace-syms))))))

;; (elcc:debug (elcc:test-worker-basic-delete) "delete : %s" x)

(defun elcc:test-worker-basic-3workers-delete ()
  (lexical-let*
      ((trace-syms '(init))
       (ctx (elcc:worker-create-context
             3 
             (lambda (worker) 
               (push 'pre-create trace-syms)
               (deferred:next 
                 (lambda ()
                   (push 'post-create trace-syms))))
              (lambda (w) 
                (push 'delete trace-syms)
                (deferred:succeed))
              (lambda (worker task) 
                (push 'pass trace-syms)
                (funcall task)
                (deferred:next 
                  (lambda () 
                    (push 'pass-end trace-syms))))
              )))
    (push (lambda () 
            (push 'ondone trace-syms))
          (elcc:worker-context-ondone-hook ctx))
    (deferred:$
      (deferred:parallel
        (elcc:worker-exec-task ctx (lambda () (push 'exec-task1 trace-syms)))
        (elcc:worker-exec-task ctx (lambda () (push 'exec-task2 trace-syms)))
        (elcc:worker-exec-task ctx (lambda () (push 'exec-task3 trace-syms))))
      (deferred:nextc it
        (lambda () (elcc:worker-wait-all ctx)))
      (deferred:nextc it
        (lambda () (elcc:worker-context-delete-worker-instance ctx (cadr (elcc:worker-context-workers ctx)))))
      (deferred:nextc it
        (lambda () 
          (push (length (elcc:worker-context-workers ctx)) trace-syms)
          (setq trace-syms (reverse trace-syms))
          (or (equal
               '(init pre-create pre-create pre-create 
                      post-create post-create post-create 
                      pass exec-task1 
                      pass exec-task2 
                      pass exec-task3 
                      pass-end pass-end pass-end 
                      ondone ondone ondone
                      delete 2)
               trace-syms) trace-syms))))))

;; (elcc:debug (elcc:test-worker-basic-3workers-delete) "3workers-delete : %s" x)

(defun elcc:test-worker-basic-delete-all ()
  (lexical-let*
      ((trace-syms '(init))
       (ctx (elcc:worker-create-context
             4 
             (lambda (worker) 
               (push 'pre-create trace-syms)
               (deferred:wait 10))
             (lambda (w) 
               (push 'delete trace-syms)
               (deferred:wait 10))
             (lambda (worker task)
               (push 'pass trace-syms)
               (deferred:wait 10)))))
    (deferred:$
      (deferred:parallel-list
        (loop for i from 0 below 4
              collect (elcc:worker-exec-task ctx (lambda () ))))
      (deferred:nextc it
        (lambda () (elcc:worker-wait-all ctx)))
      (deferred:nextc it
        (lambda () (elcc:worker-context-delete-worker-all ctx )))
      (deferred:nextc it
        (lambda () 
          (push (length (elcc:worker-context-workers ctx)) trace-syms)
          (setq trace-syms (reverse trace-syms))
          (or (equal
               '(init 
                 pre-create pre-create pre-create pre-create 
                 pass pass pass pass 
                 delete delete delete delete 0)
               trace-syms) trace-syms))))))

;; (elcc:debug (elcc:test-worker-basic-delete-all) "delete-all : %s" x)



;;; tests for process module





(defun elcc:test-all ()
  (interactive)
  (elcc:run-tests
   '(elcc:test-worker-basic 
     elcc:test-worker-basic-single-2task
     elcc:test-worker-basic-delete
     elcc:test-worker-basic-3workers-delete
     elcc:test-worker-basic-delete-all
     )
   ))

;; (progn (eval-current-buffer) (elcc:test-all))

;;; test for elcc:worker
