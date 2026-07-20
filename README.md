# macos-dictionary.el

`macos-dictionary.el` looks up words in every active dictionary configured in
macOS Dictionary.app and renders the definitions in Emacs.

Definitions are fetched as XHTML, preserving headings, emphasis, lists, tables,
links, images, and pronunciation resources that Emacs's `shr` renderer supports.
Dictionary links open the linked definition in the same Emacs interface.

## Requirements

- macOS with Dictionary.app
- Emacs 27.1 or newer, built with libxml2
- Clang and the macOS CoreServices and Foundation frameworks
- `jq` for the command-line integration test

## Installation

Add this repository to `load-path`, then load the package:

```elisp
(require 'macos-dictionary)
```

The native `macos-dictionary-cli` helper is compiled automatically when first
needed and whenever `macos-dictionary.m` is newer than the executable.

## Usage

- `macos-dictionary-search-word-at-point` looks up the region or word at point.
- `macos-dictionary-search-input` prompts for a word.
- `macos-dictionary-search` looks up a word supplied by Lisp.
- `macos-dictionary-list-dictionaries` returns the active dictionaries.

Example configuration:

```elisp
(global-set-key (kbd "C-c d") #'macos-dictionary-search-word-at-point)
(global-set-key (kbd "C-c i") #'macos-dictionary-search-input)
```

Set `macos-dictionary-use-chinese-text-segmentation` to non-nil to use the
optional `chinese-word-at-point` package when choosing a word at point.

## Tests

Run the native integration test on macOS:

```sh
tests/macos-dictionary-cli.sh
```

Load `tests/macos-dictionary-tests.el` and run the `macos-dictionary-` ERT tests
through an Emacs instance built with libxml2.

## Implementation notes

The package uses private Dictionary Services functions from CoreServices. These
functions are not covered by Apple's public compatibility guarantees and may
change in future macOS releases.

The native helper returns structured JSON. Each matching active dictionary has
its own name and list of representation-1 XHTML records. Emacs renders each
record independently so its `<base>` URL applies to relative media resources.
