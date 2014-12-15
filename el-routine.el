;;; el-routine.el --- concurrent processes

;; Copyright (C) 2014  

;; Author:  <m.sakurai at kiwanami.net>
;; Keywords: lisp

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

;;; Commentary:

;; goroutine
;;  chan
;; 
;; async
;;  startup code
;;
;; 
;; require features 
;; buffer content share

;;; Code:

(require 'epc)
(require 'epcs)


;;; Debug Utilities

(defvar elcc:debug nil "Debug output switch.")
(defvar elcc:debug-count 0 "[internal] Debug output counter.") ; debug

(defun elcc:message (&rest args)
  "Output a message into the debug buffer: *elcc:debug*."
  (when elcc:debug
    (with-current-buffer (get-buffer-create "*elcc:debug*")
      (save-excursion
        (goto-char (point-max))
        (insert (format "%5i %s\n" elcc:debug-count (apply #'format args)))))
    (incf elcc:debug-count)))

(defvar elcc:id-count 0 "[internal] for ID generation.")

(defun elcc:id-gen ()
  "[internal] Generate ID number."
  (incf elcc:id-count))


;;; Worker Dispatch Framework

;; [elcc:worker-instance]
;;  - id     : id number for debug output
;;  - data   : some data for the each worker instance
;;  - status : symbol (init / running / waiting)
(defstruct elcc:worker-instance id data status)

;; [elcc:worker-context]
;;  - max-num : maximum number of worker instances
;;  - workers : a list of elcc:worker-instance objects
;;  - create-func : worker creator function ( elcc:worker-instance -> d elcc:worker-instance )
;;  - delete-func : worker delete function  ( elcc:worker-instance -> d () )
;;  - pass-func   : pass function ( worker -> task -> d () )
;;  - ondone-hook : a list of functions which is called after a task is finished.
;;  - queue   : a list for task queue
(defstruct elcc:worker-context max-num workers create-func delete-func pass-func ondone-hook queue)

(defun elcc:worker-create-context (num-workers create-func delete-func pass-func)
  "Make a worker context."
  (when (or (null create-func) (null delete-func) (null pass-func))
    (error "Create/Delete/Pass function can not be null."))
  (when (> 1 num-workers)
    (error "Worker number should be positive integer. %S" num-workers))
  (make-elcc:worker-context 
   :max-num num-workers :create-func create-func :delete-func delete-func :pass-func pass-func))

(defun elcc:worker-create-instance ()
  "The worker creator function should call this function to create an instance."
  (make-elcc:worker-instance :id (elcc:id-gen) :status 'init))

(defun elcc:worker-exec-task (wctx task)
  "This function put the given task 
  WCTX is a `elcc:worker-context' instance. TASK is a function
  to execute, such as function symbol and lambda expression."
  (let ((d (deferred:new)))
    (setf (elcc:worker-context-queue wctx)
          (push (cons d task) (elcc:worker-context-queue wctx)))
    (elcc:worker-exec-task-gen wctx)
    d))

(defun elcc:worker-exec-task-gen (wctx)
  "[internal] Initiate workers and pop a task and execute it."
  (elcc:message "exec task gen")
  (if (elcc:worker-context-queue wctx)
      (lexical-let* 
          ((wctx wctx)
           (ptask (car (last (elcc:worker-context-queue wctx))))
           (dd (car ptask)) (task (cdr ptask))
           (worker (elcc:worker-get-waiting-worker wctx)))
        (cond
         ((null task)
          ;; do nothing : no task
          )
         (worker 
          ;; found an idle worker
          (elcc:message "task-gen : idle worker")
          (setf (elcc:worker-context-queue wctx) 
                (nbutlast (elcc:worker-context-queue wctx)))
          (elcc:worker-pass-task wctx worker task dd))
         ((<= (elcc:worker-context-max-num wctx) ; <=
              (length (elcc:worker-context-workers wctx)))
          ;; do nothing : wait for idle workers
          (elcc:message "task-gen : wait worker %i" (length (elcc:worker-context-workers wctx))))
         (t
          ;; make a new worker
          (elcc:message "task-gen : new worker %i" (length (elcc:worker-context-workers wctx)))
          (setf (elcc:worker-context-queue wctx) 
                (nbutlast (elcc:worker-context-queue wctx)))
          (lexical-let ((nworker (elcc:worker-create-instance)))
            (setf (elcc:worker-context-workers wctx)
                  (cons nworker (elcc:worker-context-workers wctx)))
            (deferred:nextc
              (funcall (elcc:worker-context-create-func wctx) nworker)
              (lambda ()
                (setf (elcc:worker-instance-status nworker) 'waiting)
                (elcc:worker-pass-task wctx nworker task dd)))))))))

(defun elcc:worker-get-waiting-worker (wctx)
  "[internal] "
  (loop for i in (elcc:worker-context-workers wctx)
        if (eq 'waiting (elcc:worker-instance-status i))
        return i))

(defun elcc:worker-pass-task (wctx worker task dd)
  "[internal] "
  (lexical-let ((wctx wctx) (worker worker) (task task) (dd dd))
    (elcc:message "task start")
    (setf (elcc:worker-instance-status worker) 'running)
    (deferred:$
      (deferred:try
        (funcall (elcc:worker-context-pass-func wctx) worker task)
        :finally
        (lambda (x)
          (elcc:message "task finished")
          (setf (elcc:worker-instance-status worker) 'waiting)
          (elcc:worker-ondone-task wctx worker)))
      (deferred:nextc it
        (lambda (x) 
          (elcc:message "task callback : %S" x)
          (deferred:callback-post dd x))))))

(defun elcc:worker-ondone-task (wctx worker)
  "[internal] "
  (elcc:message "task ondone ")
  (lexical-let ((wctx wctx))
    (deferred:next
      (lambda () (elcc:worker-exec-task-gen wctx))))
  (loop for f in (elcc:worker-context-ondone-hook wctx)
        do (ignore-errors 
             (funcall f))))

(defun elcc:worker-wait-all (wctx)
  "[Debug] Return the deferred object which waits for finishing all tasks."
  (cond
   ((= (length (elcc:worker-context-queue wctx)) 0) 
    (deferred:succeed wctx))
   (t
    (lexical-let* 
        ((wctx wctx)
         (d (deferred:new))
         (hook (lambda (x) 
                 (when (= (length (elcc:worker-context-queue wctx)) 0)
                   (setf (elcc:worker-context-ondone-hook wctx)
                         (remove hook (elcc:worker-context-ondone-hook wctx)))
                   (deferred:callback-post d)))))
      (push hook (elcc:worker-context-ondone-hook wctx))
      d))))


;;; elroutine API

(defmacro elcc:routine-d(code &rest args)
  "CODE exec code
return deferred"
  `(elcc:routine-deferred-internal ,code ,args)
  )

(defun elcc:routine-deferred-internal (code args)
  (elcc:worker-exec-task elcc:process-context (list code args)))


(defvar elcc:process-max-number 2
  "Maximum number of epc processes.")

(defvar elcc:process-context nil)

(defun elcc:create-process-d ()
  "return D epc"
  (epc:start-epc-deferred "emacs" (list "-batch" "-L" "." "-l" "el-routine-slaves.el" (format "%S" load-path))))

(defun elcc:init-process ()
  (setq elcc:process-context 
        (elcc:worker-create-context 
         elcc:process-max-number
         (lambda (worker)
           (lexical-let ((worker worker))
             (deferred:nextc
               (elcc:create-process-d)
               (lambda (epc) 
                 (elcc:message "create epc")
                 (setf (elcc:worker-instance-data worker) epc)))))
         (lambda (worker) 
           (let ((epc (elcc:worker-instance-data worker)))
             (deferred:succeed (epc:stop-epc epc))))
         (lambda (worker task)
           (lexical-let ((epc (elcc:worker-instance-data worker)))
             (epc:call-deferred epc 'exec task))))))

(elcc:init-process)

;;; demo code


(defun elcc:demo ()
  (interactive)
  (lexical-let
      ((code '(lambda (x) 
                (let* ((f (lambda (f xx) 
                            (if (> 2 xx) 1 
                              (+ (funcall f f (- xx 1)) (funcall f f (- xx 2)))))))
                  (funcall f f x))))
       (begin-time (float-time)))
    (deferred:nextc
      (deferred:parallel-list
        (loop for i from 1 below 30
              collect
              (elcc:routine-deferred-internal code (list 30))))
      (lambda (xs) 
        (message "Result: (time %s) %S " (- (float-time) begin-time) xs)))))

;; (elcc:demo)
;; (length (elcc:worker-context-workers elcc:process-context))



(provide 'el-routine)
;;; el-routine.el ends here
