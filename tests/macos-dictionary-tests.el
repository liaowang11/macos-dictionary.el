;;; macos-dictionary-tests.el --- Tests for macos-dictionary  -*- lexical-binding: t; -*-

(require 'ert)

(load (expand-file-name
       "../macos-dictionary.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defconst macos-dictionary-test--result
  '((word . "run")
    (dictionaries
     . (((name . "First Dictionary")
         (shortName . "First")
         (entries
          . (((headword . "run")
              (html . "<html><body><h2>run</h2><p><b>verb</b> move quickly; see <a href=\"x-dictionary:d:sprint\">sprint</a>.</p></body></html>")))))
        ((name . "Second Dictionary")
         (shortName . "Second")
         (entries
          . (((headword . "run")
              (html . "<html><body><h2>run</h2><p><i>noun</i> an act of running.</p></body></html>")))))))))

(defconst macos-dictionary-test--rich-html
  (concat
   "<html><head><base href=\"file:///tmp/Dictionary.dictionary/Contents/\">"
   "</head><body><d:entry><h1>semantic</h1>"
   "<div><h1 class=\"hword\">semantic</h1>"
   "<audio src=\"prons/semantic.mp3\"></audio>"
   "<img src=\"speaker.png\" onmousedown=\"audio.play()\">"
   "<ol><li><span class=\"num\">1</span> first meaning</li>"
   "<li><span class=\"num\">2</span> second meaning</li></ol>"
   "</div></d:entry></body></html>"))

(defconst macos-dictionary-test--mw-lettered-html
  (concat
   "<html><body>"
   "<div class=\"try-header\"><h1 class=\"hword\">premium</h1> "
   "<sup>1</sup><span class=\"fl\">noun</span></div> "
   "<div class=\"npf\"><div class=\"hfv\"><div class=\"rhj\">"
   "<ol class=\"lvc\">"
   "<li><span class=\"num\">1</span>"
   "<div class=\"def-item\">"
   "<span class=\"letter\">a</span>"
   "<span class=\"block\"> <span class=\"gmb\">:</span> "
   "a reward or recompense for a particular act</span>"
   "<span class=\"letter\">b</span>"
   "<span class=\"block\"> <span class=\"gmb\">:</span> "
   "a sum over and above a regular price paid chiefly as an inducement or incentive</span>"
   "<span class=\"letter\">c</span>"
   "<span class=\"block\"> <span class=\"gmb\">:</span> "
   "a sum in advance of or in addition to the nominal value of something "
   "<span class=\"ex-sent\">bonds callable at a <i>premium</i> of six percent</span></span>"
   "</div></li>"
   "<li><span class=\"num\">2</span>"
   "<div class=\"def-item\"><span class=\"block\"> "
   "<span class=\"gmb\">:</span> the consideration paid for a contract of insurance"
   "</span></div></li>"
   "</ol></div></div></div>"
   "</body></html>")
  "Merriam-Webster lettered sub-sense markup.")

(defconst macos-dictionary-test--links-html
  (concat
   "<html><body><p>see "
   "<a href=\"x-dictionary:d:one\">one</a> and "
   "<a href=\"x-dictionary:d:two\">two</a>.</p></body></html>")
  "Entry markup containing two dictionary links.")

(ert-deftest macos-dictionary-search-renders-lettered-sub-senses ()
  (let ((buffer-name " *macos-dictionary-test-mw*")
        completion)
    (unwind-protect
        (cl-letf (((symbol-function 'macos-dictionary--lookup-async)
                   (lambda (_word callback)
                     (setq completion callback)
                     'lookup-process)))
          (let ((macos-dictionary-generate-buffer-name-function
                 (lambda (_word) buffer-name)))
            (save-window-excursion
              (macos-dictionary-search "premium"))
            (funcall completion
                     'lookup-process
                     `((word . "premium")
                       (dictionaries
                        . (((name . "Merriam-Webster's Dictionary")
                            (shortName . "MW")
                            (entries
                             . (((headword . "premium")
                                 (html . ,macos-dictionary-test--mw-lettered-html))))))))
                     nil)
            (with-current-buffer buffer-name
              ;; Letters are on dedicated lines to read as a list.
              (should (= 1 (how-many "^a : a reward" (point-min) (point-max))))
              (should (= 1 (how-many "^b : a sum over" (point-min) (point-max))))
              (should (= 1 (how-many "^c : a sum in advance"
                                     (point-min) (point-max))))
              ;; Other spans still render inline.
              (should (= 1 (how-many "the consideration paid for a contract"
                                     (point-min) (point-max)))))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest macos-dictionary-search-renders-all-rich-definitions ()
  (let ((buffer-name " *macos-dictionary-test*")
        completion)
    (unwind-protect
        (cl-letf (((symbol-function 'macos-dictionary--lookup-async)
                   (lambda (_word callback)
                     (setq completion callback)
                     'lookup-process)))
          (let ((macos-dictionary-generate-buffer-name-function
                 (lambda (_word) buffer-name)))
            (save-window-excursion
              (macos-dictionary-search "run"))
            (funcall completion
                     'lookup-process macos-dictionary-test--result nil)
            (with-current-buffer buffer-name
              (goto-char (point-min))
              (should (search-forward "First Dictionary" nil t))
              (should (search-forward "Second Dictionary" nil t))
              (goto-char (point-min))
              (should (search-forward "verb" nil t))
              (should (get-text-property (1- (point)) 'face))
              (should (search-forward "sprint" nil t))
              (should (equal (get-text-property (1- (point)) 'shr-url)
                             "x-dictionary:d:sprint")))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest macos-dictionary-search-renders-after-async-lookup ()
  (let ((buffer-name " *macos-dictionary-async-test*")
        completion)
    (unwind-protect
        (cl-letf (((symbol-function 'macos-dictionary--lookup)
                   (lambda (_word)
                     (error "Synchronous lookup called")))
                  ((symbol-function 'macos-dictionary--lookup-async)
                   (lambda (_word callback)
                     (setq completion callback)
                     'lookup-process)))
          (let ((macos-dictionary-generate-buffer-name-function
                 (lambda (_word) buffer-name)))
            (save-window-excursion
              (macos-dictionary-search "run"))
            (with-current-buffer buffer-name
              (should (equal macos-dictionary-current-word "run"))
              (should (equal (buffer-string) "Looking up “run”…\n")))
            (should completion)
            (funcall completion
                     'lookup-process macos-dictionary-test--result nil)
            (with-current-buffer buffer-name
              (goto-char (point-min))
              (should (search-forward "First Dictionary" nil t)))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest macos-dictionary-async-lookup-parses-process-output ()
  (let (completion process)
    (unwind-protect
        (cl-letf (((symbol-function
                    'macos-dictionary-cli-find-or-recompile)
                   (lambda () "/bin/echo")))
          (setq process
                (macos-dictionary--lookup-async
                 "{\"word\":\"echo\",\"dictionaries\":[]}"
                 (lambda (_process result error)
                   (setq completion (list result error)))))
          (let ((deadline (+ (float-time) 2)))
            (while (and (null completion)
                        (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (should completion)
          (should-not (cadr completion))
          (should (equal (alist-get 'word (car completion)) "echo")))
      (when (and (processp process) (process-live-p process))
        (delete-process process)))))

(ert-deftest macos-dictionary-links-search-for-the-linked-term ()
  (let (searched-word)
    (cl-letf (((symbol-function 'macos-dictionary-search)
               (lambda (word) (setq searched-word word))))
      (with-temp-buffer
        (macos-dictionary-mode)
        (browse-url "x-dictionary:d:back%20up")))
    (should (equal searched-word "back up"))))

(ert-deftest macos-dictionary-links-drop-the-dictionary-segment ()
  (let (searched-word)
    (cl-letf (((symbol-function 'macos-dictionary-search)
               (lambda (word) (setq searched-word word))))
      (with-temp-buffer
        (macos-dictionary-mode)
        (browse-url "x-dictionary:d:contractor:com.apple.dictionary.Noad")))
    (should (equal searched-word "contractor"))))

(ert-deftest macos-dictionary-history-push-records-visits ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (macos-dictionary--push-history "cat")
    (macos-dictionary--push-history "dog")
    (should (equal macos-dictionary--history '("cat" "dog")))
    (should (eq macos-dictionary--history-index 1))))

(ert-deftest macos-dictionary-history-move-navigates-back-and-forward ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (macos-dictionary--push-history "cat")
    (macos-dictionary--push-history "dog")
    (macos-dictionary--push-history "bird")
    (should (equal (macos-dictionary--history-move -1) "dog"))
    (should (eq macos-dictionary--history-index 1))
    (should (equal (macos-dictionary--history-move -1) "cat"))
    (should (null (macos-dictionary--history-move -1)))
    (should (equal (macos-dictionary--history-move 1) "dog"))
    (should (equal (macos-dictionary--history-move 1) "bird"))
    (should (null (macos-dictionary--history-move 1)))))

(ert-deftest macos-dictionary-history-push-truncates-the-forward-tail ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (macos-dictionary--push-history "cat")
    (macos-dictionary--push-history "dog")
    (macos-dictionary--push-history "bird")
    (macos-dictionary--history-move -1)
    (macos-dictionary--push-history "fish")
    (should (equal macos-dictionary--history '("cat" "dog" "fish")))
    (should (eq macos-dictionary--history-index 2))
    (should (null (macos-dictionary--history-move 1)))))

(ert-deftest macos-dictionary-history-back-renders-the-previous-word ()
  (let ((buffer-name " *macos-dictionary-history-back-test*")
        completion
        lookup-token)
    (unwind-protect
        (cl-letf (((symbol-function 'macos-dictionary--lookup-async)
                   (lambda (_word callback)
                     (setq completion callback
                           lookup-token (1+ (or lookup-token 0)))
                     lookup-token)))
          (let ((macos-dictionary-generate-buffer-name-function
                 (lambda (_word) buffer-name)))
            (save-window-excursion
              (macos-dictionary-search "cat"))
            (funcall completion lookup-token
                     '((word . "cat") (dictionaries)) nil)
            (save-window-excursion
              (macos-dictionary-search "dog"))
            (funcall completion lookup-token
                     '((word . "dog") (dictionaries)) nil)
            (with-current-buffer buffer-name
              (should (equal macos-dictionary-current-word "dog"))
              (macos-dictionary-history-back)
              (should (equal macos-dictionary-current-word "cat")))
            (funcall completion lookup-token
                     '((word . "cat") (dictionaries)) nil)
            (with-current-buffer buffer-name
              (should (equal (buffer-string) "No definition found.\n")))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(defun macos-dictionary-test--insert-links ()
  "Render `macos-dictionary-test--links-html' in the current buffer."
  (macos-dictionary-mode)
  (let ((inhibit-read-only t))
    (macos-dictionary--insert-html macos-dictionary-test--links-html)))

(ert-deftest macos-dictionary-tab-moves-to-the-next-link ()
  (with-temp-buffer
    (macos-dictionary-test--insert-links)
    (goto-char (point-min))
    (call-interactively (key-binding (kbd "TAB")))
    (should (equal (get-text-property (point) 'shr-url) "x-dictionary:d:one"))
    (call-interactively (key-binding (kbd "TAB")))
    (should (equal (get-text-property (point) 'shr-url) "x-dictionary:d:two"))))

(ert-deftest macos-dictionary-backtab-moves-to-the-previous-link ()
  (with-temp-buffer
    (macos-dictionary-test--insert-links)
    (goto-char (point-max))
    (call-interactively (key-binding (kbd "<backtab>")))
    (should (equal (get-text-property (point) 'shr-url) "x-dictionary:d:two"))
    (call-interactively (key-binding (kbd "<backtab>")))
    (should (equal (get-text-property (point) 'shr-url) "x-dictionary:d:one"))))

(ert-deftest macos-dictionary-mode-shows-key-hints-in-the-header-line ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (should header-line-format)
    (should (equal header-line-format
                   macos-dictionary-mode-header-line-format))
    (should (cl-find-if
             (lambda (item)
               (and (stringp item) (string-prefix-p ": WebKit" item)))
             header-line-format))))

(ert-deftest macos-dictionary-header-line-shows-the-current-word ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (should-not (string-match-p
                 "premium"
                 (format-mode-line header-line-format nil nil
                                   (current-buffer))))
    (cl-letf (((symbol-function 'macos-dictionary--lookup-async)
               (lambda (_word _callback) 'lookup-process)))
      (macos-dictionary--render-into (current-buffer) "100%premium"))
    (should (string-prefix-p
             "100%premium"
             (format-mode-line header-line-format nil nil
                               (current-buffer))))))

(ert-deftest macos-dictionary-audio-links-use-the-audio-handler ()
  (with-temp-buffer
    (macos-dictionary-mode)
    (should
     (eq (browse-url-select-handler
          "file:///tmp/Dictionary.dictionary/Contents/prons/semantic.mp3")
         #'macos-dictionary--play-audio))))

(ert-deftest macos-dictionary-audio-handler-plays-the-decoded-file ()
  (let (process-arguments)
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_file) t))
              ((symbol-function 'start-process)
               (lambda (&rest arguments)
                 (setq process-arguments arguments))))
      (macos-dictionary--play-audio
       "file:///tmp/Dictionary%20Name.dictionary/Contents/prons/semantic.mp3"))
    (should
     (equal process-arguments
            '("macos-dictionary-audio" nil "afplay"
              "/tmp/Dictionary Name.dictionary/Contents/prons/semantic.mp3")))))

(ert-deftest macos-dictionary-normalizes-dictionary-html ()
  (with-temp-buffer
    (macos-dictionary--insert-html macos-dictionary-test--rich-html)
    (let ((rendered (buffer-substring-no-properties (point-min) (point-max))))
      (should (= (how-many "semantic" (point-min) (point-max)) 1))
      (should-not (string-match-p "1 1" rendered))
      (should-not (string-match-p "2 2" rendered))
      (should (= (how-many "\\[audio\\]" (point-min) (point-max)) 1))
      (should-not (text-property-not-all
                   (point-min) (point-max) 'display nil)))
    (goto-char (point-min))
    (search-forward "semantic")
    (should (equal (get-text-property (1- (point)) 'macos-dictionary-html)
                   macos-dictionary-test--rich-html))))

(ert-deftest macos-dictionary-webkit-action-opens-the-entry-at-point ()
  (let (opened-html)
    (cl-letf (((symbol-function 'macos-dictionary--browse-html-in-webkit)
               (lambda (html) (setq opened-html html))))
      (with-temp-buffer
        (macos-dictionary-mode)
        (let ((inhibit-read-only t))
          (macos-dictionary--insert-html macos-dictionary-test--rich-html))
        (goto-char (point-min))
        (search-forward "semantic")
        (macos-dictionary-view-in-webkit)))
    (should (equal opened-html macos-dictionary-test--rich-html))))

(ert-deftest macos-dictionary-webkit-view-uses-a-temporary-html-file ()
  (let ((webkit-buffer (generate-new-buffer " *macos-dictionary-webkit-test*"))
        opened-url
        opened-new-session
        temporary-file)
    (unwind-protect
        (cl-letf (((symbol-function 'xwidget-webkit-browse-url)
                   (lambda (url new-session)
                     (setq opened-url url
                           opened-new-session new-session)
                     (set-buffer webkit-buffer))))
          (save-current-buffer
            (macos-dictionary--browse-html-in-webkit
             macos-dictionary-test--rich-html))
          (with-current-buffer webkit-buffer
            (setq temporary-file macos-dictionary--webkit-temp-file)
            (should (equal (with-temp-buffer
                             (insert-file-contents temporary-file)
                             (buffer-string))
                           macos-dictionary-test--rich-html)))
          (should opened-new-session)
          (should (equal opened-url (browse-url-file-url temporary-file))))
      (when (buffer-live-p webkit-buffer)
        (kill-buffer webkit-buffer))
      (when (and temporary-file (file-exists-p temporary-file))
        (delete-file temporary-file)))
    (should-not (file-exists-p temporary-file))))

(provide 'macos-dictionary-tests)

;;; macos-dictionary-tests.el ends here
