;;; el-routine-slaves.el --- slave code for concurrent processes

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

;; [see the document]

;;; Code:

;; passed load-path with command line argument as a sexp.
(let ((init-path (read (nth 5 command-line-args))))
  (setq load-path init-path))

(require 'epcs)

(defvar elcc:slave-stop-flag nil
  "If t, this program evacuates the event loop.")

(defun elcc:slave-init (mngr)
  (epc:define-method mngr 'exec #'elcc:slave-task-start "[task code] [task argument list]" "Execute a new task.")
  (epc:define-method mngr 'shutdown #'elcc:slave-stop "[no args]" "Stop the event loop of this slave process.")
  mngr)

(defun elcc:slave-stop ()
  (setq elcc:slave-stop-flag t))

(defun elcc:slave-task-start (code args)
  (apply code args))

(when noninteractive
  (setq epcs (epcs:server-start #'elcc:slave-init))
  ;; Start "event loop".
  (while (not elcc:slave-stop-flag)
    (sleep-for 0.1)))
