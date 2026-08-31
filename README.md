# ProjectCoordinator.jl

Runs student group projects on GitHub, from a menu.

For each group it creates the project repository, fills it from a template with
the Julia package renamed, protects `main` so every change arrives by pull
request, creates the course's milestones, and creates the group's team with
access to its project. It invites students to the organisation from a list of
email addresses, shows who has joined and which groups they are in, manages a
group's members and their roles, and writes a report of where every project
stood at each deadline.

Everything goes through the `gh` command line tool, so no credential is stored
here. Nothing about a particular course, organisation or GitHub host is built
into the code: a course is a short TOML file.

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
students listed in `invitees.txt`, write a report, and manage each group's
members.

## The report

**Write report** writes `report.md` into the course's own directory, beside the
configuration that produced it.

It has a section per project: the group and its members, then one section per
milestone. Each milestone names the last commit on `main` before its deadline
and links to the repository at that commit, so marking is reading a tree at a
fixed point rather than whatever the repository holds today. Students keep
working after a deadline; the link does not move.

Under each milestone are two lists, **Issues** and **Pull Requests**, of what
happened between the previous deadline and this one — one row per event, with
the title, who opened the item, the kind of activity, and when:

```markdown
| | title | opened by | activity | when |
| --- | --- | --- | --- | --- |
| [#15](…/pull/15) | Read measurement files | tvarga | opened | 2026-09-30 14:10 |
| [#17](…/pull/17) | Try a spline fit instead | akowalski | closed | 2026-10-05 09:26 |
| [#15](…/pull/15) | Read measurement files | tvarga | merged | 2026-10-06 18:22 |
```

Activity is grouped by *when it happened*, not by which milestone anybody
assigned it to, since students often assign nothing. An item opened before one
deadline and merged after it therefore appears under both. A pull request
closed without being merged is its own kind of event: counting it as merged
would credit abandoned work, and leaving it out would hide that the work was
done and thrown away.

Deadlines are read as local time. A commit carries an absolute instant and a
timezone offset that only affects how it is displayed, so the comparison is
made on the instant.

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
