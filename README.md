# macos-dictionary.el

Look up words from macOS Dictionary.app without leaving Emacs.

This project is a fork of Xuchun Yang's
[`osx-dictionary.el`](https://github.com/xuchunyang/osx-dictionary.el). It keeps
the original package's simple Emacs interface while replacing its dictionary
lookup and rendering pipeline. The package was renamed to `macos-dictionary`
to use Apple's current platform name and to distinguish the fork's API.

## What's new in this fork

| Capability | Upstream `osx-dictionary.el` | This fork |
| --- | --- | --- |
| Dictionary coverage | Searches only the default dictionary | Searches every dictionary enabled in Dictionary.app |
| Result coverage | Returns one incomplete, plain-text-oriented result | Returns every exact matching entry, grouped by dictionary |
| Dictionary data | Requests Dictionary Services representation 3 | Requests representation 1 XHTML, as used by Raycast's Define Word command |
| Rendering | Inserts a lossy native text conversion | Renders semantic XHTML with Emacs's native `shr` renderer |
| Rich content | Formatting and structure are discarded | Preserves supported headings, emphasis, lists, tables, links, images, and pronunciation resources |
| Dictionary links | Not interactive | Opens `x-dictionary:` links in the same Emacs interface |
| Pronunciation audio | Not interactive | Plays local dictionary audio with `afplay` |
| Full-fidelity view | Not available | Opens the entry at point in WebKit when Emacs has xwidget support |
| Native-to-Emacs transport | Ad hoc formatted text | Structured JSON containing dictionaries and entries |
| Native helper | Built manually | Compiled automatically on first use and after source changes |
| Test coverage | None | Native integration tests and ERT rendering tests |

The renderer preserves the semantic content that `shr` supports. It does not
attempt to reproduce Dictionary.app's complete WebKit CSS and layout. Before
rendering, it removes presentation artifacts caused by CSS and JavaScript that
`shr` cannot apply, such as hidden metadata headings, duplicate list numbers,
and redundant speaker images.

## Requirements

- macOS with Dictionary.app
- Emacs 27.1 or newer, built with libxml2
- Emacs built with xwidget support for the optional WebKit view
- Clang and the macOS CoreServices and Foundation frameworks
- `jq` when running the native integration test

The package uses private Dictionary Services functions from CoreServices.
Apple does not provide compatibility guarantees for these functions, so future
macOS releases may require changes.

## Installation

Clone the repository and add it to `load-path`, then load the package:

```elisp
(add-to-list 'load-path "/path/to/macos-dictionary.el")
(require 'macos-dictionary)
```

The native `macos-dictionary-cli` helper is compiled automatically when first
needed and whenever `macos-dictionary.m` is newer than the executable.

This fork deliberately uses new `macos-dictionary-*` names and does not provide
compatibility aliases for the upstream `osx-dictionary-*` API.

## Usage

- `M-x macos-dictionary-search-word-at-point` looks up the active region or the
  word at point.
- `M-x macos-dictionary-search-input` prompts for a word.
- `macos-dictionary-search` looks up a word supplied by Lisp.
- `macos-dictionary-list-dictionaries` returns the active dictionaries.

Example configuration:

```elisp
(global-set-key (kbd "C-c d") #'macos-dictionary-search-word-at-point)
(global-set-key (kbd "C-c i") #'macos-dictionary-search-input)
```

Inside a definition buffer:

- `s` prompts for another word.
- `o` opens the current word in Dictionary.app.
- `r` reads the current word with the macOS `say` command.
- `w` opens the entry at point in WebKit.
- `q` closes the buffer and restores the previous window configuration.

Press `RET` or click a rendered `[audio]` link to play that dictionary's
recorded pronunciation with `afplay`.

Set `macos-dictionary-use-chinese-text-segmentation` to non-nil to use the
optional [`chinese-word-at-point`](https://github.com/xuchunyang/chinese-word-at-point.el)
package when choosing a word at point.

## Tests

Run the native end-to-end integration test on macOS:

```sh
tests/macos-dictionary-cli.sh
```

Load `tests/macos-dictionary-tests.el` and run the `macos-dictionary-` ERT tests
through an Emacs instance built with libxml2.

## How it works

The native helper asks Dictionary Services for all active dictionaries, finds
exact case-insensitive matches, and returns representation-1 XHTML records as
structured JSON. Emacs renders each record separately so its `<base>` URL can
resolve relative links and media resources.

This design is informed by reverse engineering Raycast's Define Word command,
which also queries active Dictionary Services dictionaries and requests record
representation 1.
