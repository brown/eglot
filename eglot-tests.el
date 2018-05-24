;;; eglot-tests.el --- Tests for eglot.el            -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Free Software Foundation, Inc.

;; Author: João Távora <joaotavora@gmail.com>
;; Keywords: tests

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for eglot.el

;;; Code:
(require 'eglot)
(require 'cl-lib)
(require 'ert)
(require 'edebug)

;; Helpers

(defmacro eglot--with-dirs-and-files (dirs &rest body)
  (declare (indent 1) (debug t))
  `(eglot--call-with-dirs-and-files
    ,dirs #'(lambda () ,@body)))

(defun eglot--make-file-or-dirs (ass)
  (let ((file-or-dir-name (car ass))
        (content (cdr ass)))
    (cond ((listp content)
           (make-directory file-or-dir-name 'parents)
           (let ((default-directory (concat default-directory "/" file-or-dir-name)))
             (mapc #'eglot--make-file-or-dirs content)))
          ((stringp content)
           (with-temp-buffer
             (insert content)
             (write-region nil nil file-or-dir-name nil 'nomessage)))
          (t
           (message "[yas] oops don't know this content")))))

(defun eglot--call-with-dirs-and-files (dirs fn)
  (let* ((default-directory (make-temp-file "eglot--fixture" t))
         new-buffers new-servers)
    (unwind-protect
        (let ((find-file-hook
               (cons (lambda () (push (current-buffer) new-buffers))
                     find-file-hook))
              (eglot-connect-hook
               (lambda (server) (push server new-servers))))
          (mapc #'eglot--make-file-or-dirs dirs)
          (funcall fn))
      (eglot--message "Killing buffers %s,  deleting %s, killing %s"
                      (mapconcat #'buffer-name new-buffers ", ")
                      default-directory
                      (mapcar #'eglot--name new-servers))
      (unwind-protect
          (let ((eglot-autoreconnect nil))
            (mapc #'eglot-shutdown
                  (cl-remove-if-not (lambda (server) (process-live-p (eglot--process server)))
                                    new-servers)))
        (mapc #'kill-buffer (mapcar #'eglot--events-buffer new-servers))
        (dolist (buf new-buffers) ;; have to save otherwise will get prompted
          (with-current-buffer buf (save-buffer) (kill-buffer)))
        (delete-directory default-directory 'recursive)))))

(cl-defmacro eglot--with-timeout (timeout &body body)
  (declare (indent 1) (debug t))
  `(eglot--call-with-timeout ',timeout (lambda () ,@body)))

(defun eglot--call-with-timeout (timeout fn)
  (let* ((tag (gensym "eglot-test-timeout"))
         (timed-out (make-symbol "timeout"))
         (timeout-and-message
          (if (listp timeout) timeout
            (list timeout "waiting for test to finish")))
         (timeout (car timeout-and-message))
         (message (cadr timeout-and-message))
         (timer)
         (retval))
    (unwind-protect
        (setq retval
              (catch tag
                (setq timer
                      (run-with-timer timeout nil
                                      (lambda ()
                                        (unless edebug-active
                                          (throw tag timed-out)))))
                (funcall fn)))
      (cancel-timer timer)
      (when (eq retval timed-out)
        (error "%s" (concat "Timed out " message))))))

(defun eglot--find-file-noselect (file &optional noerror)
  (unless (or noerror
              (file-readable-p file)) (error "%s does not exist" file))
  (find-file-noselect file))

(cl-defmacro eglot--sniffing ((&key server-requests
                                    server-notifications
                                    server-replies
                                    client-requests
                                    client-notifications
                                    client-replies)
                              &rest body)
  "Run BODY saving LSP JSON messages in variables, most recent first."
  (declare (indent 1) (debug (sexp &rest form)))
  (let ((log-event-ad-sym (make-symbol "eglot--event-sniff")))
    `(unwind-protect
         (let ,(delq nil (list server-requests
                               server-notifications
                               server-replies
                               client-requests
                               client-notifications
                               client-replies))
           (advice-add
            #'eglot--log-event :before
            (lambda (_proc message &optional type)
              (cl-destructuring-bind (&key method id _error &allow-other-keys)
                  message
                (let ((req-p (and method id))
                      (notif-p method)
                      (reply-p id))
                  (cond
                   ((eq type 'server)
                    (cond (req-p ,(when server-requests
                                    `(push message ,server-requests)))
                          (notif-p ,(when server-notifications
                                      `(push message ,server-notifications)))
                          (reply-p ,(when server-replies
                                      `(push message ,server-replies)))))
                   ((eq type 'client)
                    (cond (req-p ,(when client-requests
                                    `(push message ,client-requests)))
                          (notif-p ,(when client-notifications
                                      `(push message ,client-notifications)))
                          (reply-p ,(when client-replies
                                      `(push message ,client-replies)))))))))
            '((name . ,log-event-ad-sym)))
           ,@body)
       (advice-remove #'eglot--log-event ',log-event-ad-sym))))

(defmacro eglot--wait-for (events-sym fn timeout)
  "Spin until FN match in EVENTS-SYM, flush events after it.
Pass TIMEOUT to `eglot--with-timeout'."
  `(eglot--with-timeout ,timeout
     (let ((event
            (cl-loop thereis (cl-loop for json in ,events-sym
                                      when (funcall ,fn json) return
                                      (cons json before)
                                      collect json into before)
                     do
                     ;; `read-event' is essential to have the file
                     ;; watchers come through.
                     (read-event "[eglot] Waiting a bit..." nil 0.1)
                     (accept-process-output nil 0.1))))
       (setq ,events-sym (cdr event))
       (message "[eglot] Event detected:\n%s"
                (pp-to-string (car event))))))


;; `rust-mode' is not a part of emacs. So define these two shims which
;; should be more than enough for testing
(unless (functionp 'rust-mode)
  (define-derived-mode rust-mode prog-mode "Rust"))
(add-to-list 'auto-mode-alist '("\\.rs\\'" . rust-mode))


(ert-deftest dummy () "A dummy test" (should t))

(ert-deftest auto-detect-running-server ()
  "Visit a file and M-x eglot, then visit a neighbour. "
  (skip-unless (executable-find "rls"))
  (let (server)
    (eglot--with-dirs-and-files
        '(("project" . (("coiso.rs" . "bla")
                        ("merdix.rs" . "bla")))
          ("anotherproject" . (("cena.rs" . "bla"))))
      (eglot--with-timeout 2
        (with-current-buffer
            (eglot--find-file-noselect "project/coiso.rs")
          (should (setq server (apply #'eglot (eglot--interactive))))
          (should (eglot--current-server)))
        (with-current-buffer
            (eglot--find-file-noselect "project/merdix.rs")
          (should (eglot--current-server))
          (should (eq (eglot--current-server) server)))
        (with-current-buffer
            (eglot--find-file-noselect "anotherproject/cena.rs")
          (should-error (eglot--current-server-or-lose)))))))

(ert-deftest auto-reconnect ()
  "Start a server. Kill it. Watch it reconnect."
  (skip-unless (executable-find "rls"))
  (let (server (eglot-autoreconnect 1))
    (eglot--with-dirs-and-files
        '(("project" . (("coiso.rs" . "bla")
                        ("merdix.rs" . "bla"))))
      (eglot--with-timeout 3
        (with-current-buffer
            (eglot--find-file-noselect "project/coiso.rs")
          (should (setq server (apply #'eglot (eglot--interactive))))
          ;; In 1.2 seconds > `eglot-autoreconnect' kill servers. We
          ;; should have a automatic reconnection.
          (run-with-timer 1.2 nil (lambda () (delete-process
                                              (eglot--process server))))
          (while (process-live-p (eglot--process server))
            (accept-process-output nil 0.5))
          (should (eglot--current-server))
          ;; Now try again too quickly
          (setq server (eglot--current-server))
          (run-with-timer 0.5 nil (lambda () (delete-process
                                              (eglot--process server))))
          (while (process-live-p (eglot--process server))
            (accept-process-output nil 0.5))
          (should (not (eglot--current-server))))))))

(ert-deftest rls-watches-files ()
  "Start RLS server.  Notify it when a critical file changes."
  (skip-unless (executable-find "rls"))
  (skip-unless (executable-find "cargo"))
  (skip-unless (null (getenv "TRAVIS_TESTING")))
  (let ((eglot-autoreconnect 1))
    (eglot--with-dirs-and-files
        '(("project" . (("coiso.rs" . "bla")
                        ("merdix.rs" . "bla"))))
      (eglot--with-timeout 10
        (with-current-buffer
            (eglot--find-file-noselect "project/coiso.rs")
          (should (zerop (shell-command "cargo init")))
          (eglot--sniffing (
                            :server-requests s-requests
                            :client-notifications c-notifs
                            :client-replies c-replies
                            )
            (should (apply #'eglot (eglot--interactive)))
            (let (register-id)
              (eglot--wait-for s-requests
                               (eglot--lambda (&key id method &allow-other-keys)
                                 (setq register-id id)
                                 (string= method "client/registerCapability"))
                               (1 "waiting for registerCapability request"))
              (eglot--wait-for c-replies
                               (eglot--lambda (&key id error &allow-other-keys)
                                 (and (eq id register-id) (null error)))
                               (1 "waiting for client reply")))
            (delete-file "Cargo.toml")
            (eglot--wait-for
             c-notifs
             (eglot--lambda (&key method params &allow-other-keys)
               (and (eq method :workspace/didChangeWatchedFiles)
                    (cl-destructuring-bind (&key uri type)
                        (elt (plist-get params :changes) 0)
                      (and (string= (eglot--path-to-uri "Cargo.toml") uri)
                           (= type 3)))))
             (3 "waiting for didChangeWatchedFiles notification"))))))))

(ert-deftest basic-completions ()
  "Test basic autocompletion in a python LSP"
  (skip-unless (executable-find "pyls"))
  (eglot--with-dirs-and-files
      '(("project" . (("something.py" . "import sys\nsys.exi"))))
    (eglot--with-timeout 4
      (with-current-buffer
          (eglot--find-file-noselect "project/something.py")
        (should (apply #'eglot (eglot--interactive)))
        (goto-char (point-max))
        (completion-at-point)
        (should (looking-back "sys.exit"))))))

(ert-deftest hover-after-completions ()
  "Test basic autocompletion in a python LSP"
  (skip-unless (executable-find "pyls"))
  (eglot--with-dirs-and-files
      '(("project" . (("something.py" . "import sys\nsys.exi"))))
    (eglot--with-timeout 4
      (with-current-buffer
          (eglot--find-file-noselect "project/something.py")
        (should (apply #'eglot (eglot--interactive)))
        (goto-char (point-max))
        (setq eldoc-last-message nil)
        (completion-at-point)
        (should (looking-back "sys.exit"))
        (while (not eldoc-last-message) (accept-process-output nil 0.1))
        (should (string-match "^exit" eldoc-last-message))))))

(provide 'eglot-tests)
;;; eglot-tests.el ends here

;; Local Variables:
;; checkdoc-force-docstrings-flag: nil
;; End:
