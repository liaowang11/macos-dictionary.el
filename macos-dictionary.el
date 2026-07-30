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
(require 'url-parse)
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

(defcustom macos-dictionary-mode-header-line-format
  '((:propertize "s" face mode-line-buffer-id)
    ": Search Word    "
    (:propertize "o" face mode-line-buffer-id)
    ": Dictionary.app    "
    (:propertize "r" face mode-line-buffer-id)
    ": Read Word    "
    (:propertize "w" face mode-line-buffer-id)
    ": WebKit    "
    (:propertize "q" face mode-line-buffer-id)
    ": Quit")
  "Header line displayed in `macos-dictionary-mode' buffers.
Set this to nil to hide the header line."
  :type '(choice (const :tag "No header line" nil) sexp)
  :group 'macos-dictionary)

(defconst macos-dictionary-cli "macos-dictionary-cli"
  "Executable compiled from macos-dictionary.m.")

(defconst macos-dictionary--load-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the package files.")

(defvar macos-dictionary-buffer-name "*macos-dictionary*")

(defvar-local macos-dictionary-current-word nil
  "Word displayed in the current dictionary buffer.")

(defvar-local macos-dictionary--lookup-process nil
  "Asynchronous lookup process for the current dictionary buffer.")

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
    (define-key map (kbd "w") #'macos-dictionary-view-in-webkit)
    map)
  "Keymap for `macos-dictionary-mode'.")

(defvar macos-dictionary-previous-window-configuration nil
  "Window configuration from before displaying a definition.")

(defvar-local macos-dictionary--history nil
  "Words visited in this buffer, oldest first.")

(defvar-local macos-dictionary--history-index 0
  "Index into `macos-dictionary--history' of the word shown now.")

(define-derived-mode macos-dictionary-mode special-mode "macos-dictionary"
  "Major mode for definitions returned by macOS Dictionary Services."
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'macos-dictionary--cancel-lookup nil t)
  (setq-local header-line-format
              macos-dictionary-mode-header-line-format)
  (setq-local browse-url-handlers
              (append
               '(("\\`x-dictionary:d:" . macos-dictionary--browse-url)
                 ("\\`file:.*\\.\\(?:mp3\\|m4a\\|wav\\|aiff?\\)"
                  . macos-dictionary--play-audio))
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

(defun macos-dictionary--lookup-async (word callback)
  "Look up WORD asynchronously, then call CALLBACK.
CALLBACK receives the process, parsed result, and error message.
Exactly one of the result and error arguments is non-nil."
  (let* ((executable (macos-dictionary-cli-find-or-recompile))
         (output-buffer
          (generate-new-buffer " *macos-dictionary-cli*")))
    (make-process
     :name "macos-dictionary-lookup"
     :buffer output-buffer
     :command (list executable word)
     :connection-type 'pipe
     :noquery t
     :sentinel
     (lambda (process event)
       (when (memq (process-status process) '(exit signal))
         (unwind-protect
             (if (and (eq (process-status process) 'exit)
                      (zerop (process-exit-status process)))
                 (let (result parse-error)
                   (condition-case error
                       (setq result
                             (with-current-buffer (process-buffer process)
                               (goto-char (point-min))
                               (json-parse-buffer
                                :object-type 'alist
                                :array-type 'list
                                :null-object nil
                                :false-object nil)))
                     (error
                      (setq parse-error (error-message-string error))))
                   (funcall callback process result parse-error))
               (let ((output
                      (with-current-buffer (process-buffer process)
                        (string-trim (buffer-string)))))
                 (funcall
                  callback process nil
                  (if (string-empty-p output)
                      (string-trim event)
                    output))))
           (when (buffer-live-p (process-buffer process))
             (kill-buffer (process-buffer process)))))))))

(defun macos-dictionary-list-dictionaries ()
  "Return the active macOS dictionaries as a list of alists."
  (macos-dictionary--run-cli "--list"))

(defun macos-dictionary--dom-class-p (node class)
  "Return non-nil when DOM NODE has CLASS."
  (and (consp node)
       (member class (split-string (or (dom-attr node 'class) "")))))

(defun macos-dictionary--dom-has-class-p (node class)
  "Return non-nil when DOM NODE or a descendant has CLASS."
  (and (consp node)
       (or (macos-dictionary--dom-class-p node class)
           (cl-some (lambda (child)
                      (macos-dictionary--dom-has-class-p child class))
                    (dom-children node)))))

(defun macos-dictionary--explicit-numbered-list-p (node)
  "Return non-nil when DOM NODE supplies its own item numbers."
  (when (and (consp node) (eq (dom-tag node) 'ol))
    (let ((items
           (cl-remove-if-not
            (lambda (child)
              (and (consp child) (eq (dom-tag child) 'li)))
            (dom-children node))))
      (and items
           (cl-every (lambda (item)
                       (macos-dictionary--dom-has-class-p item "num"))
                     items)))))

(defun macos-dictionary--normalize-dom (node &optional parent-tag)
  "Normalize Dictionary XHTML DOM NODE for `shr'.
PARENT-TAG is the tag containing NODE."
  (cond
   ((not (consp node)) node)
   ((and (eq parent-tag 'd:entry)
         (eq (dom-tag node) 'h1)
         (not (dom-attr node 'class)))
    nil)
   ((and (eq (dom-tag node) 'img)
         (string-match-p
          "\\.play[[:space:]]*("
          (or (dom-attr node 'onmousedown) "")))
    nil)
   (t
    (let* ((tag (dom-tag node))
           (attributes (dom-attributes node))
           (explicit-numbering
            (macos-dictionary--explicit-numbered-list-p node))
           (children
            (delq
             nil
             (mapcar
              (lambda (child)
                (let ((normalized
                       (macos-dictionary--normalize-dom child tag)))
                  (if (and explicit-numbering
                           (consp normalized)
                           (eq (dom-tag normalized) 'li))
                      (cons 'div (cdr normalized))
                    normalized)))
              (dom-children node)))))
      (cons (if explicit-numbering 'div tag)
            (cons attributes children))))))

(defun macos-dictionary--render-span (dom)
  "Render span DOM, starting Merriam-Webster lettered sub-senses on new lines.
Merriam-Webster marks sub-senses with inline <span class=\"letter\">s,
which shr otherwise concatenates into one long line."
  (if (not (member "letter" (split-string (or (dom-attr dom 'class) ""))))
      (shr-generic dom)
    (unless (zerop (current-column))
      (insert "\n"))
    ;; Drop any surrounding <li> continuation indentation so the
    ;; lettered list starts at the left margin.
    (let ((shr-indentation 0))
      (shr-generic dom))))

(defun macos-dictionary--insert-html (html)
  "Render HTML at point using Emacs's simple HTML renderer."
  (let ((start (point))
        (shr-use-colors t)
        (shr-use-fonts t)
        (shr-inhibit-images nil)
        (shr-external-rendering-functions
         '((span . macos-dictionary--render-span))))
    (shr-insert-document
     (macos-dictionary--normalize-dom
      (with-temp-buffer
        (insert html)
        (libxml-parse-html-region (point-min) (point-max)))))
    (add-text-properties
     start (point) `(macos-dictionary-html ,html))))

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
  (let ((buffer (macos-dictionary--get-buffer word)))
    (macos-dictionary--render-into buffer word)
    (with-current-buffer buffer
      (macos-dictionary--push-history word))
    (macos-dictionary--display-buffer buffer)))

(defun macos-dictionary--render-into (buffer word)
  "Look up WORD and render its definitions into BUFFER."
  (with-current-buffer buffer
    (macos-dictionary--cancel-lookup)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq macos-dictionary-current-word word)
      (insert (format "Looking up “%s”…\n" word))
      (goto-char (point-min))))
  (let ((process
         (macos-dictionary--lookup-async
          word
          (lambda (process result error)
            (macos-dictionary--finish-render
             buffer process result error)))))
    (with-current-buffer buffer
      (setq macos-dictionary--lookup-process process))))

(defun macos-dictionary--finish-render (buffer process result error)
  "Render RESULT or ERROR in BUFFER if PROCESS is its active lookup."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (eq process macos-dictionary--lookup-process)
        (setq macos-dictionary--lookup-process nil)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (if error
              (insert (format "Dictionary lookup failed: %s\n" error))
            (macos-dictionary--insert-result result))
          (goto-char (point-min)))))))

(defun macos-dictionary--cancel-lookup ()
  "Cancel the current buffer's asynchronous dictionary lookup."
  (let ((process macos-dictionary--lookup-process))
    (setq macos-dictionary--lookup-process nil)
    (when (and (processp process) (process-live-p process))
      (delete-process process))))

(defun macos-dictionary--push-history (word)
  "Record WORD as a new visit in this buffer.
Do nothing when WORD is the word already shown.  Words visited
after the current position are discarded, as in a web browser."
  (cond
   ((null macos-dictionary--history)
    (setq macos-dictionary--history (list word)
          macos-dictionary--history-index 0))
   ((equal word (nth macos-dictionary--history-index
                     macos-dictionary--history))
    nil)
   (t
    (let ((kept (cl-subseq macos-dictionary--history
                           0 (1+ macos-dictionary--history-index))))
      (setq macos-dictionary--history (append kept (list word))
            macos-dictionary--history-index
            (1- (length macos-dictionary--history)))))))

(defun macos-dictionary--history-move (delta)
  "Move the history position by DELTA and return the word now shown.
Return nil when there is no word in that direction."
  (if (null macos-dictionary--history)
      nil
    (let* ((last (1- (length macos-dictionary--history)))
           (next (max 0 (min last (+ macos-dictionary--history-index delta)))))
      (if (= next macos-dictionary--history-index)
          nil
        (setq macos-dictionary--history-index next)
        (nth next macos-dictionary--history)))))

(defun macos-dictionary-history-back ()
  "Show the previously visited word in this dictionary buffer."
  (interactive)
  (macos-dictionary--history-navigate -1))

(defun macos-dictionary-history-forward ()
  "Show the next visited word in this dictionary buffer."
  (interactive)
  (macos-dictionary--history-navigate 1))

(defun macos-dictionary--history-navigate (delta)
  "Re-render the word DELTA steps away in history."
  (if-let* ((word (macos-dictionary--history-move delta)))
      (macos-dictionary--render-into (current-buffer) word)
    (message "No %s dictionary history"
             (if (< delta 0) "earlier" "later"))))

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
  "Look up the dictionary term encoded in URL.

The `x-dictionary:d:' scheme links the headword to either the
bare term or a term followed by a dictionary bundle id
(`x-dictionary:d:WORD:BUNDLE_ID'); the bundle id selects a source
in Dictionary.app and is not part of the search term."
  (let ((body (string-remove-prefix "x-dictionary:d:" url)))
    (macos-dictionary-search
     (url-unhex-string
      (car (split-string body ":"))))))

(defun macos-dictionary--play-audio (url &rest _arguments)
  "Play the local audio file at URL."
  (let* ((parsed-url (url-generic-parse-url url))
         (file (url-unhex-string (url-filename parsed-url))))
    (unless (and (equal (url-type parsed-url) "file")
                 (file-readable-p file))
      (user-error "Audio file is not readable: %s" url))
    (start-process "macos-dictionary-audio" nil "afplay" file)))

(defvar-local macos-dictionary--webkit-temp-file nil
  "Temporary XHTML file displayed by the current WebKit buffer.")

(defun macos-dictionary--delete-webkit-temp-file ()
  "Delete the XHTML file associated with the current WebKit buffer."
  (when (and macos-dictionary--webkit-temp-file
             (file-exists-p macos-dictionary--webkit-temp-file))
    (delete-file macos-dictionary--webkit-temp-file)))

(defun macos-dictionary--browse-html-in-webkit (html)
  "Display HTML in a new WebKit session."
  (unless (fboundp 'xwidget-webkit-browse-url)
    (user-error "This Emacs was not built with WebKit support"))
  (let ((file (make-temp-file "macos-dictionary-" nil ".html"))
        opened)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert html))
          (xwidget-webkit-browse-url (browse-url-file-url file) t)
          (setq-local macos-dictionary--webkit-temp-file file)
          (add-hook 'kill-buffer-hook
                    #'macos-dictionary--delete-webkit-temp-file nil t)
          (setq opened t))
      (unless opened
        (when (file-exists-p file)
          (delete-file file))))))

(defun macos-dictionary-view-in-webkit ()
  "Display the dictionary entry at point in WebKit."
  (interactive)
  (let ((html
         (or (get-text-property (point) 'macos-dictionary-html)
             (and (> (point) (point-min))
                  (get-text-property (1- (point))
                                     'macos-dictionary-html)))))
    (unless html
      (user-error "No dictionary entry at point"))
    (macos-dictionary--browse-html-in-webkit html)))

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
