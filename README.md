# notes

notes is a command line utility that helps to find notes (both existing and just links to non-existing ones), find duplicate notes and rename notes. This program is a part of the neovim plugin that hasn't been uploaded yet.

To determine the title of a note it uses the `title` field in YAML frontmatter, or uses filename if there is no YAML frontmatter.

notes only uses wikilinks, so it ignores normal markdown links.

## Installation

Install [zig](https://ziglang.org/download) 0.14.0-dev.3298+6fe1993d8 or later.

```bash
git clone https://github.com/cynumini/notes
cd notes
zig build -Doptimize=ReleaseFast -p ~/.local # this means it will put the bin file in ~/.local/bin
```

> [!WARNING]
> This program has only been tested on Linux. It won't work on Windows, and probably not on macOS either.

## Commands

For now notes have the 3 command.

### json

```bash
notes json ~/notes
```

It will return all your notes in the ~/notes folder in this format:

```json
{
  "My note 1": "my-note-1.md",
  "my-note-2": "my-note-2.md",
  "my-note-3": "subfolder/my-note-3.md",
  "My note 4": null
}
```

In this example, `my-note-1.md` has YAML frontmatter with title, and `my-note-2.md` and `my-note-3.md` don't. If there are notes with the same title, the program returns the one with the shortest path. To check if there are duplicates use the `duplicate` command.

`My note 4` on the other hand is not a file, but a link to a non-existent file in `my-note-1.md`.

### duplicate

It prints a list of notes that have the same title.

```bash
notes duplicate ~/notes
```

This gives this result:

```
Duplicate: my-note-1.md - subfolder/my-note-5.md
```

In this example my `my-note-1` and `my-note-5` have the same title in YAML frontmatter.

### rename

Rename the note title and all links in other files.

```bash
notes rename ~/notes "my-note-2" "My note 2"
```

In this example, since `my-note-2.md` doesn't have YAML frontmatter, it will insert it with the new title `My note 2` and after that, if there are other notes with links on `my-note-2`, they will be renamed to `My note 2`.
