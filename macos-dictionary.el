;;; macos-dictionary.el --- Interface for macOS Dictionary.app  -*- lexical-binding: t; -*-

;; Copyright (C) 2014-2016 Chunyang Xu

;; Author: Chunyang Xu <mail@xuchunyang.me>
;; Maintainer: liaowang11
;; URL: https://github.com/liaowang11/macos-dictionary.el
;; Package-Requires: ((emacs "27.1"))
;; Keywords: mac, dictionary
;; Version: 0.5

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Look up words using the active dictionaries configured in Dictionary.app
;; and render their rich definitions in an Emacs buffer.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'shr)
(require 'subr-x)
(require 'url-util)

(defgroup macos-dictionary nil
  "macOS Dictionary.app interface for Emacs."
  :group 'external)

(defcustom macos-dictionary-use-chinese-text-segmentation nil
  "Whether to use an external Chinese text segmentation package."
  :type 'boolean
  :group 'macos-dictionary)

(defcustom macos-dictionary-search-log-file nil
  "File in which to save lookup history, or nil to disable logging."
  :type '(choice (const :tag "Do not save lookup history" nil)
                 (file :tag "History file"))
  :group 'macos-dictionary)

(defcustom macos-dictionary-separator "────────────────────\n"
  "Separator inserted between definitions from one dictionary."
  :type 'string
  :group 'macos-dictionary)

(defconst macos-dictionary-cli "macos-dictionary-cli"
  "Executable compiled from macos-dictionary.m.")

(defconst macos-dictionary--load-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the package files.")

(defvar macos-dictionary-buffer-name "*macos-dictionary*")

(defvar-local macos-dictionary-current-word nil
  "Word displayed in the current dictionary buffer.")

(defun macos-dictionary-generate-buffer-name-default-function (_word)
  "Return the default dictionary buffer name."
  macos-dictionary-buffer-name)

(defcustom macos-dictionary-generate-buffer-name-function
  #'macos-dictionary-generate-buffer-name-default-function
  "Function called with a word to choose its result buffer name."
  :group 'macos-dictionary
  :type 'function)

(defvar macos-dictionary-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'macos-dictionary-quit)
    (define-key map (kbd "s") #'macos-dictionary-search-input)
    (define-key map (kbd "o") #'macos-dictionary-open-in-dictionary)
    (define-key map (kbd "r") #'macos-dictionary-read-word)
    map)
  "Keymap for `macos-dictionary-mode'.")

(defvar macos-dictionary-previous-window-configuration nil
  "Window configuration from before displaying a definition.")

(define-derived-mode macos-dictionary-mode special-mode "macos-dictionary"
  "Major mode for definitions returned by macOS Dictionary Services."
  (visual-line-mode 1)
  (setq-local browse-url-handlers
              (cons '("\\`x-dictionary:d:" . macos-dictionary--browse-url)
                    browse-url-handlers)))

(defun macos-dictionary-open-in-dictionary ()
  "Open the current word in Dictionary.app."
  (interactive)
  (unless macos-dictionary-current-word
    (user-error "No dictionary word is displayed"))
  (browse-url (concat "dict://"
                      (url-hexify-string macos-dictionary-current-word))))

(defun macos-dictionary-read-word ()
  "Read the current word using the macOS speech synthesizer."
  (interactive)
  (unless macos-dictionary-current-word
    (user-error "No dictionary word is displayed"))
  (start-process "macos-dictionary-speech" nil
                 "say" macos-dictionary-current-word))

(defun macos-dictionary-quit ()
  "Restore the previous window configuration and bury this buffer."
  (interactive)
  (when (window-configuration-p
         macos-dictionary-previous-window-configuration)
    (set-window-configuration
     macos-dictionary-previous-window-configuration)
    (setq macos-dictionary-previous-window-configuration nil))
  (bury-buffer))

(defun macos-dictionary--get-buffer (word)
  "Return the dictionary result buffer for WORD."
  (let ((buffer
         (get-buffer-create
          (funcall macos-dictionary-generate-buffer-name-function word))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'macos-dictionary-mode)
        (macos-dictionary-mode)))
    buffer))

(defun macos-dictionary--display-buffer (buffer)
  "Display BUFFER while remembering the current window configuration."
  (setq macos-dictionary-previous-window-configuration
        (current-window-configuration))
  (let ((window (get-buffer-window buffer)))
    (if window
        (select-window window)
      (switch-to-buffer-other-window buffer))))

(defun macos-dictionary--executable-file ()
  "Return the package-local CLI path."
  (expand-file-name macos-dictionary-cli macos-dictionary--load-directory))

(defun macos-dictionary-recompile ()
  "Compile and return the path to `macos-dictionary-cli'."
  (interactive)
  (let* ((default-directory macos-dictionary--load-directory)
         (source (expand-file-name "macos-dictionary.m"))
         (executable (macos-dictionary--executable-file))
         (status (process-file
                  "clang" nil "*macos-dictionary-build*" nil
                  "-O2" "-framework" "CoreServices"
                  "-framework" "Foundation"
                  source "-o" executable)))
    (unless (zerop status)
      (error "Failed to compile %s; see *macos-dictionary-build*" source))
    executable))

(defun macos-dictionary-cli-find-or-recompile ()
  "Return an up-to-date `macos-dictionary-cli' executable."
  (let* ((source (expand-file-name
                  "macos-dictionary.m" macos-dictionary--load-directory))
         (local-executable (macos-dictionary--executable-file))
         (executable (or (executable-find local-executable)
                         (executable-find macos-dictionary-cli))))
    (if (and executable
             (not (file-newer-than-file-p source executable)))
        executable
      (macos-dictionary-recompile))))

(defun macos-dictionary--run-cli (&rest arguments)
  "Run the dictionary CLI with ARGUMENTS and parse its JSON output."
  (with-temp-buffer
    (let ((status (apply #'process-file
                         (macos-dictionary-cli-find-or-recompile)
                         nil t nil arguments)))
      (unless (zerop status)
        (error "macos-dictionary-cli failed: %s" (string-trim (buffer-string))))
      (goto-char (point-min))
      (json-parse-buffer :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil))))

(defun macos-dictionary--lookup (word)
  "Return structured definitions for WORD."
  (macos-dictionary--run-cli word))

(defun macos-dictionary-list-dictionaries ()
  "Return the active macOS dictionaries as a list of alists."
  (macos-dictionary--run-cli "--list"))

(defun macos-dictionary--insert-html (html)
  "Render HTML at point using Emacs's simple HTML renderer."
  (let ((start (point))
        (shr-use-colors t)
        (shr-use-fonts t)
        (shr-inhibit-images nil))
    (insert html)
    (shr-render-region start (point))))

(defun macos-dictionary--insert-result (result)
  "Insert a parsed dictionary RESULT at point."
  (let ((dictionaries (alist-get 'dictionaries result)))
    (if (null dictionaries)
        (insert "No definition found.\n")
      (cl-loop
       for dictionary in dictionaries
       for dictionary-index from 0
       do
       (when (> dictionary-index 0)
         (insert "\n"))
       (insert (propertize (alist-get 'name dictionary)
                           'face 'outline-1)
               "\n\n")
       (cl-loop
        for entry in (alist-get 'entries dictionary)
        for entry-index from 0
        do
        (when (> entry-index 0)
          (insert macos-dictionary-separator))
        (macos-dictionary--insert-html (alist-get 'html entry))
        (insert "\n"))))))

;;;###autoload
(defun macos-dictionary-search (word)
  "Look up WORD and display all rich definitions."
  (interactive "sWord: ")
  (when macos-dictionary-search-log-file
    (append-to-file
     (concat word "\n") nil
     (expand-file-name macos-dictionary-search-log-file)))
  (let ((result (macos-dictionary--lookup word))
        (buffer (macos-dictionary--get-buffer word)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq macos-dictionary-current-word word)
        (macos-dictionary--insert-result result)
        (goto-char (point-min))))
    (macos-dictionary--display-buffer buffer)))

;;;###autoload
(defun macos-dictionary-search-input ()
  "Prompt for a word and display its definitions."
  (interactive)
  (let* ((default (macos-dictionary--region-or-word))
         (prompt (if default (format "Word (%s): " default) "Word: "))
         (word (read-string prompt nil nil default)))
    (macos-dictionary-search word)))

;;;###autoload
(defun macos-dictionary-search-pointer ()
  "Display definitions for the region or word at point."
  (interactive)
  (if-let* ((word (macos-dictionary--region-or-word)))
      (macos-dictionary-search word)
    (message "Nothing to look up")))

;;;###autoload
(defalias 'macos-dictionary-search-word-at-point
  #'macos-dictionary-search-pointer)

(defun macos-dictionary--browse-url (url &rest _arguments)
  "Look up the dictionary term encoded in URL."
  (macos-dictionary-search
   (url-unhex-string
    (string-remove-prefix "x-dictionary:d:" url))))

(defun macos-dictionary--region-or-word ()
  "Return the active region or the word at point."
  (if (use-region-p)
      (buffer-substring-no-properties (region-beginning) (region-end))
    (if macos-dictionary-use-chinese-text-segmentation
        (if (require 'chinese-word-at-point nil t)
            (thing-at-point 'chinese-or-other-word)
          (user-error "The package chinese-word-at-point is not installed"))
      (thing-at-point 'word t))))

(provide 'macos-dictionary)

;;; macos-dictionary.el ends here
