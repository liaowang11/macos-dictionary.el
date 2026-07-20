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

(ert-deftest macos-dictionary-search-renders-all-rich-definitions ()
  (let ((buffer-name " *macos-dictionary-test*"))
    (unwind-protect
        (cl-letf (((symbol-function 'macos-dictionary--lookup)
                   (lambda (_word) macos-dictionary-test--result)))
          (let ((macos-dictionary-generate-buffer-name-function
                 (lambda (_word) buffer-name)))
            (save-window-excursion
              (macos-dictionary-search "run"))
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

(ert-deftest macos-dictionary-links-search-for-the-linked-term ()
  (let (searched-word)
    (cl-letf (((symbol-function 'macos-dictionary-search)
               (lambda (word) (setq searched-word word))))
      (with-temp-buffer
        (macos-dictionary-mode)
        (browse-url "x-dictionary:d:back%20up")))
    (should (equal searched-word "back up"))))

(provide 'macos-dictionary-tests)

;;; macos-dictionary-tests.el ends here
