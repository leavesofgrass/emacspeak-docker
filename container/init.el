;;; init.el --- container init: start emacspeak before anything else
;; The DTK_PROGRAM environment variable (set by /usr/local/bin/emacspeak,
;; default dtk-soft) selects the speech server.

(setenv "EMACSPEAK_DIR" "/opt/emacspeak")
(load-file "/opt/emacspeak/lisp/emacspeak-setup.el")

;; Reasonable defaults for a console screen-reader session; change freely.
(setq inhibit-startup-screen t)
(menu-bar-mode -1)

;;; init.el ends here
