# Reading and validating the description of a course.
#
# Configuration is split in two so that the part which repeats is written
# once:
#
#   defaults.toml                          owner, host, template repository,
#                                          naming patterns
#   courses/<course-cohort>/course.toml    course, cohort
#
# A course file is merged onto the defaults. Setting up next year's course is
# then copying one short directory and changing the cohort.
#
# One directory per course-cohort, rather than one file, so that everything
# about a cohort sits together: its configuration, the list of people to
# invite, and whatever the coordinator writes there later.
#
# The directory holding them is given as an argument, defaulting to the current
# directory. Nothing is searched for: no environment variable, no fallback
# location. That is what lets the tool be pointed at a scratch copy.

"""
    config_root(path = pwd())

Check that `path` holds a configuration and return it as an absolute path.

A configuration is a `defaults.toml` and a `courses/` directory beside it. If
either is missing, say which and stop, rather than looking anywhere else.
"""
function config_root(path::AbstractString = pwd())
    root = abspath(expanduser(path))

    isdir(root) || error("no such directory: $root")
    isfile(joinpath(root, "defaults.toml")) || error("no defaults.toml in $root")
    isdir(joinpath(root, "courses")) || error("no courses/ directory in $root")

    return root
end

"""
    list_courses(root)

Return the names of the courses in `root/courses`, sorted.

A course is a directory holding a `course.toml`.
"""
function list_courses(root::AbstractString)
    courses = readdir(joinpath(root, "courses"))
    return sort([c for c in courses if isfile(course_file(c, root))])
end

"""
    course_dir(name, root)

Return the directory holding everything about course `name`.
"""
course_dir(name::AbstractString, root::AbstractString) = joinpath(root, "courses", name)

"""
    course_file(name, root)

Return the path of a course's `course.toml`.
"""
course_file(name::AbstractString, root::AbstractString) =
    joinpath(course_dir(name, root), "course.toml")

"""
    load_course(name, root)

Read `defaults.toml` and the configuration for course `name`, merge them,
check that everything required is present, and return the result.
"""
function load_course(name::AbstractString, root::AbstractString)
    file = course_file(name, root)
    isfile(file) || error("no such course: $file")

    course = merge_onto(TOML.parsefile(joinpath(root, "defaults.toml")),
                        TOML.parsefile(file))

    for key in ("owner", "template", "course", "cohort")
        haskey(course, key) || error("$name: no `$key` in the course file or defaults.toml")
    end
    haskey(course, "naming") || error("$name: no [naming] section")
    for key in ("group_id", "repo", "package")
        haskey(course["naming"], key) || error("$name: no `$key` in [naming]")
    end

    return course
end

# A course file is merged onto the defaults, section by section, so that a
# course can override one naming pattern without restating the rest.
function merge_onto(defaults::AbstractDict, course::AbstractDict)
    merged = copy(defaults)
    for (key, value) in course
        merged[key] = if value isa AbstractDict && get(defaults, key, nothing) isa AbstractDict
            merge_onto(defaults[key], value)
        else
            value
        end
    end
    return merged
end

"""
    expand(pattern, course, n)

Fill a naming pattern in for group `n`.

Placeholders are `{course}`, `{cohort}`, `{n}` and `{n2}`, the last being the
group number padded to two digits. So `"group-{n}-{course}-{cohort}"` becomes
`"group-1-scientific-programming-2026"`.
"""
function expand(pattern::AbstractString, course, n::Integer)
    return replace(pattern,
                   "{course}" => course["course"],
                   "{cohort}" => string(course["cohort"]),
                   "{n2}"     => lpad(n, 2, '0'),
                   "{n}"      => string(n))
end

"""
    pattern_regex(pattern, course)

Turn a naming pattern into a regular expression that matches the names it
produces and captures the group number.

This is `expand` run backwards, and it is how the coordinator learns which
groups exist: it reads the names GitHub actually has rather than assuming they
run from 1 to n. `\\Q...\\E` quotes the literal parts, so a course whose name
contains a regex character cannot break the match.
"""
function pattern_regex(pattern::AbstractString, course)
    fixed = replace(pattern,
                    "{course}" => course["course"],
                    "{cohort}" => string(course["cohort"]))

    parts = split(fixed, r"\{n2?\}"; limit = 2)
    length(parts) == 2 || error("naming pattern has no {n}: $pattern")

    return Regex("^\\Q" * parts[1] * "\\E(\\d+)\\Q" * parts[2] * "\\E\$")
end

"""
    invitees(name, root)

Return the email addresses in a course's `invitees.txt`, one per line.

Blank lines and lines beginning with `#` are ignored, so the file can be
annotated and pasted into without being tidied first. An absent file means
nobody is waiting to be invited, which is not an error.
"""
function invitees(name::AbstractString, root::AbstractString)
    file = joinpath(course_dir(name, root), "invitees.txt")
    isfile(file) || return String[]

    addresses = String[]
    for line in eachline(file)
        address = strip(line)
        (isempty(address) || startswith(address, "#")) && continue
        push!(addresses, String(address))
    end
    return addresses
end

