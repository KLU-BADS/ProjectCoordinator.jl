# ProjectCoordinator.jl

Creates one project repository per group for a student course, by cloning a
template and renaming the Julia package inside it.

Nothing about a particular course, organisation or GitHub host is built into
the code. A course is a short TOML file.

## Configuration

Two files. `defaults.toml` holds what stays the same every year — the owner,
the template repository, and how repositories are named. The course file holds
what changes:

```toml
course = "scientific-programming"
cohort = 2026
```

The two live in one directory: `defaults.toml` at its root, and one directory
per course-cohort under `courses/`:

```
defaults.toml
courses/scientific-programming-2026/course.toml
courses/scientific-programming-2026/invitees.txt
```

`invitees.txt` is one email address per line; blank lines and lines starting
with `#` are ignored. Everything about a cohort stays in its own directory.
See `examples/`.

## Usage

```julia
using ProjectCoordinator
menu("/path/to/your/configs")
```

The one argument is optional. `menu(path)` reads the configuration from `path`;
`menu()` reads it from the current directory. Nothing else is consulted: no
environment variable, no fallback location.

The directory must hold `defaults.toml` and a `courses/` subdirectory. If it
does not, the coordinator says what is missing and stops, rather than looking
elsewhere.

It then asks which course to work on, and offers to add projects, invite the
students listed in `invitees.txt`, and manage each group's members.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/KLU-BADS/ProjectCoordinator.jl")
```

You also need `gh`, logged in:

```bash
gh auth login
```

`gh` keeps the token. This package never stores one.

## Status

Nothing is implemented yet. `create` is declared and errors.
