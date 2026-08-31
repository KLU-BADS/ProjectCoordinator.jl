"""
    ProjectCoordinator

Creates one project repository per group, for one course-cohort, by cloning a
template and renaming the package inside it.

Nothing about a particular course, organisation or GitHub host is built in.
A course is described by a TOML file; see `courses/`.
"""
module ProjectCoordinator

using Dates
using REPL
using TOML

export create, menu

include("github.jl")
include("config.jl")
include("create.jl")
include("report.jl")
include("menu.jl")

end # module ProjectCoordinator
