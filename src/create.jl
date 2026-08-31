# Creating the project repositories.
#
# Per group:
#
#   1. POST /orgs/{org}/repos                 the repository, empty and public
#   2. POST /repos/{org}/{repo}/pages         {"build_type": "workflow"}
#   3. clone the template, rename the package, push
#
# Pages is enabled before the push, not after: the push is what starts the
# Documentation workflow, and a workflow that runs before Pages exists fails to
# deploy. Enabling first means the group's first look at their repository has a
# green badge rather than a failed run.
#
# Step 3 is a plain text substitution over the clone, then one commit:
#
#   https://github.com/KLU-BADS/ProjectTemplate.jl.git  -> the clone URL
#   https://klu-bads.github.io/ProjectTemplate.jl/      -> the Pages URL
#   cd ProjectTemplate.jl      -> cd <the repository name>            (README)
#   ProjectTemplate            -> the `package` pattern, e.g. Project1
#   src/ProjectTemplate.jl     -> src/Project1.jl                     (filename)
#   Copyright (c) 2026         -> the year now, from the system clock  (LICENSE)
#
# The template holds its own real values rather than placeholders, so its links
# resolve and it can be checked by running it. Order matters: the two URLs and
# then `ProjectTemplate.jl` must be replaced before the bare `ProjectTemplate`,
# or the longer strings are destroyed by the shorter rule. Afterwards, assert
# that no occurrence of the template's owner or name survives -- unlike a
# placeholder, a missed value looks plausible instead of obviously wrong.
#
# The copyright holder in the LICENSE stays "The authors" and needs no
# substitution; who they are is in Project.toml. Only the year is replaced, and
# it comes from the clock rather than from `cohort`, which is a label and not
# necessarily a year.
#
# `authors` in Project.toml is deliberately left alone. Filling in their names
# and university email addresses is the students' first deliverable.
#
# Renaming here is why the template carries no rename script for students.

"""
    create(name, groups; root = pwd(), dry_run = true)

Create the project repository for each of `groups` groups of course `name`.

With `dry_run = true`, the default, nothing is sent: the steps that would be
taken are returned, one string per group, so that they can be shown first.

Re-running with a larger `groups` is how a group is added later: whatever
already exists is skipped.
"""
function create(name::AbstractString, groups::Integer;
                root::AbstractString = pwd(), dry_run::Bool = true)
    error("Not implemented yet.")
end

"""
    survey(name, root)

Return the projects that exist on GitHub for course `name`, sorted by group
number.

Each entry is `(n, repo, team)`. A project is a repository whose name matches
the `repo` pattern; `n` is the number in that name. `team` is the group the
project belongs to, or `nothing` if it has none -- a group can be deleted, the
project cannot be touched by anyone but you, so the project is the record and
the group is what may be missing from it.

A group that has been renamed no longer matches the `group_id` pattern, but it
keeps its access to the project, so it is looked up through the project instead.

Read only.
"""
function survey(name::AbstractString, root::AbstractString)
    course = load_course(name, root)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    repo_pattern = pattern_regex(course["naming"]["repo"], course)
    projects = Tuple{Int,String}[]
    for repo in ghlines("/orgs/$owner/repos", ".[].name"; hostname = host)
        matched = match(repo_pattern, repo)
        matched === nothing || push!(projects, (parse(Int, matched.captures[1]), repo))
    end
    sort!(projects)

    team_pattern = pattern_regex(course["naming"]["group_id"], course)
    by_number = Dict{Int,String}()
    for team in ghlines("/orgs/$owner/teams", ".[].slug"; hostname = host)
        matched = match(team_pattern, team)
        matched === nothing || (by_number[parse(Int, matched.captures[1])] = team)
    end

    parent = expand(course["naming"]["parent_team"], course, 0)
    claimed = Set{String}()
    entries = NamedTuple[]

    for (n, repo) in projects
        team = get(by_number, n, nothing)

        if team === nothing
            shared = ghlines("/repos/$owner/$repo/teams", ".[].slug"; hostname = host)
            other = filter(t -> t != parent && !(t in claimed), shared)
            isempty(other) || (team = first(other))
        end

        team === nothing || push!(claimed, team)
        push!(entries, (n = n, repo = repo, team = team))
    end

    return entries
end

"""
    project_url(repo, course)

Return the address of one project repository.
"""
function project_url(repo::AbstractString, course)
    return "https://github.com/$(course["owner"])/$repo"
end

"""
    team_url(team, course)

Return the address of one group's team.
"""
function team_url(team::AbstractString, course)
    return "https://github.com/orgs/$(course["owner"])/teams/$team"
end

# The operations on one group.
#
# Each is one or two REST calls and nothing else. The menu decides which of
# them to offer for a given group and asks before the destructive ones; none
# of that judgement belongs here.

"""
    announce_milestones(repo, course)

Open one issue pointing at the project's milestones.

Milestones are hard to reach: with no issues at all GitHub replaces the issues
view with its "Welcome to issues!" panel, which does not draw the Milestones
button, so the milestones cannot be navigated to. This issue makes them
reachable and puts the link where the group will see it.

It is deliberately not assigned to a milestone, so that it does not count in
any milestone's percentage.
"""
function announce_milestones(repo::AbstractString, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    ghapi("POST", "/repos/$owner/$repo/issues";
          fields = ["title" => "Complete all milestones",
                    "body" => "https://github.com/$owner/$repo/milestones"],
          hostname = host)
    return nothing
end

"""
    create_group(n, course)

Make sure group `n` exists, is under the course's parent team, and has the
group's project.

If the team is already there it is used as it is, so a half-finished earlier
run is completed rather than refused.

The team is created with `group_id` as its name, so that the name GitHub turns
into the URL is the one the configuration predicts. Sending a display name
instead would give a slug that no pattern matches.
"""
function create_group(n::Integer, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    require_scopes(["admin:org"]; hostname = host)

    parent = expand(course["naming"]["parent_team"], course, n)
    parent_id = ghapi("GET", "/orgs/$owner/teams/$parent"; jq = ".id", hostname = host)
    isempty(parent_id) && error("no parent team $parent in $owner")

    name = expand(course["naming"]["group_id"], course, n)

    # A team of that name may already be there -- left behind by a run that
    # failed later, or made by hand. Creating it would fail with 422 and stop
    # everything after, so an existing team is used rather than refused: what
    # matters is that the group ends up correct, not that this call made it.
    team = find_team(name, course)
    if team === nothing
        team = ghapi("POST", "/orgs/$owner/teams";
                     fields = ["name" => name,
                               "parent_team_id" => parent_id,
                               "privacy" => "closed"],
                     jq = ".slug", hostname = host)

        # GitHub makes whoever creates a team a maintainer of it. Staff belong
        # in the parent team, not in the groups, so that membership is undone
        # here: the group should list students and nobody else. Only for a team
        # this call made -- an existing one's membership is not ours to change.
        me = gh_login(; hostname = host)
        ghapi("DELETE", "/orgs/$owner/teams/$team/memberships/$me"; hostname = host)
    end

    # A group exists to work on a project, so it is attached whether the team
    # was just made or found. Attaching twice is harmless: the call sets the
    # permission rather than adding a second grant.
    repo = expand(course["naming"]["repo"], course, n)
    ghapi("PUT", "/orgs/$owner/teams/$team/repos/$owner/$repo";
          fields = ["permission" => course["repos"]["permission"]],
          hostname = host)

    return team
end

"""
    find_team(name, course)

Return the team called `name`, or `nothing` if the organisation has no such
team.

Asked by listing rather than by fetching the team directly, because a missing
team is an ordinary answer here and `GET /orgs/{org}/teams/{name}` answers 404,
which `ghapi` turns into an error.
"""
function find_team(name::AbstractString, course)
    owner = course["owner"]
    teams = ghlines("/orgs/$owner/teams", ".[].slug";
                    hostname = get(course, "hostname", nothing))
    return name in teams ? name : nothing
end

"""
    delete_group(team, course)

Delete a group's team. Destructive.
"""
function delete_group(team::AbstractString, course)
    owner = course["owner"]
    ghapi("DELETE", "/orgs/$owner/teams/$team"; hostname = get(course, "hostname", nothing))
    return nothing
end

"""
    delete_project(repo, course)

Delete a group's project repository, and everything in it. Destructive, and
not undoable: the commits go with it.
"""
function delete_project(repo::AbstractString, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    require_scopes(["delete_repo"]; hostname = host)
    ghapi("DELETE", "/repos/$owner/$repo"; hostname = host)
    return nothing
end

"""
    members(team, course)

Return a group's members as `(login, role)`, sorted, where `role` is
`"maintainer"` or `"member"`.
"""
function members(team::AbstractString, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    people = NamedTuple[]
    for role in ("maintainer", "member")
        for login in ghlines("/orgs/$owner/teams/$team/members?role=$role", ".[].login";
                             hostname = host)
            push!(people, (login = login, role = role))
        end
    end

    return sort(people; by = p -> p.login)
end

"""
    set_role(team, user, role, course)

Make `user` a `"maintainer"` or a `"member"` of a group.

This changes the role in place. It is the same endpoint as `add_member`, which
is why changing somebody's role never costs them their membership.
"""
function set_role(team::AbstractString, user::AbstractString,
                  role::AbstractString, course)
    owner = course["owner"]
    require_scopes(["admin:org"]; hostname = get(course, "hostname", nothing))
    ghapi("PUT", "/orgs/$owner/teams/$team/memberships/$user";
          fields = ["role" => role],
          hostname = get(course, "hostname", nothing))
    return nothing
end

"""
    add_member(team, user, course)

Add `user` to a group as an ordinary member.
"""
add_member(team::AbstractString, user::AbstractString, course) =
    set_role(team, user, "member", course)

"""
    remove_member(team, user, course)

Remove `user` from a group. Destructive.
"""
function remove_member(team::AbstractString, user::AbstractString, course)
    owner = course["owner"]
    require_scopes(["admin:org"]; hostname = get(course, "hostname", nothing))
    ghapi("DELETE", "/orgs/$owner/teams/$team/memberships/$user";
          hostname = get(course, "hostname", nothing))
    return nothing
end

"""
    create_project(n, course)

Create the project repository for group `n`, fill it from the template, and
create the group that owns it.
"""
function create_project(n::Integer, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    repo = expand(course["naming"]["repo"], course, n)
    package = expand(course["naming"]["package"], course, n)

    # Everything the whole operation needs, before any of it is done. A project
    # and its group are made together or not at all: a scope missing at the
    # last step would otherwise leave a repository behind with no group.
    require_scopes(["repo", "admin:org"]; hostname = host)

    ghapi("POST", "/orgs/$owner/repos";
          fields = ["name" => repo,
                    "private" => course["repos"]["visibility"] != "public"],
          hostname = host)

    # Before the push, not after: the push starts the documentation workflow,
    # and a workflow that deploys before Pages exists fails.
    ghapi("POST", "/repos/$owner/$repo/pages";
          fields = ["build_type" => course["repos"]["pages"]],
          hostname = host)

    fill_project(repo, package, course)

    # After the push: there is no `main` to protect until something is on it.
    protect_main(repo, course)

    create_milestones(repo, course)
    announce_milestones(repo, course)

    # A project always has a group. The two are made together, so the only
    # repair the menu ever needs is recreating a group somebody deleted.
    create_group(n, course)

    return repo
end

"""
    create_milestones(repo, course)
    announce_milestones(repo, course)

Create the course's milestones in one project.

Milestones are per repository, so every group gets its own copy of the same
list, and each group's progress is counted against its own issues.

A `deadline` is a local date and time. GitHub keeps only the date part of what
it is sent, and which date it keeps depends on a normalisation it does not
document, so the date it shows is not necessarily the date given here.
"""
function create_milestones(repo::AbstractString, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    for milestone in get(course, "milestone", [])
        fields = Pair{String,Any}["title" => milestone["title"]]
        description = get(milestone, "description", "")

        if haskey(milestone, "deadline")
            deadline = milestone["deadline"]
            push!(fields, "due_on" => Dates.format(deadline, "yyyy-mm-ddTHH:MM:SSZ"))

            # GitHub's own due date is a date, and the date it displays is not
            # always the one it was given, so the deadline is stated in the
            # description as well -- in words, with its time, where it cannot
            # be rounded or reinterpreted. First line, so it shows in the
            # milestone list preview.
            description = "**Deadline:** " * Dates.format(deadline, "e, d U yyyy, HH:MM") *
                          " " * local_zone(deadline) * "\n\n" * description
        end

        isempty(description) || push!(fields, "description" => description)

        ghapi("POST", "/repos/$owner/$repo/milestones";
              fields = fields, hostname = host)
    end
    return nothing
end

"""
    protect_main(repo, course)

Require a pull request for every change to `main`.

Nobody can push to `main` afterwards, administrators and organisation owners
included, so the branch always holds work that arrived through a pull request.
No approving review is demanded -- the rule is about how a change arrives, not
about who signs it off.

The body is nested and its four keys are all required, which is why it goes as
JSON rather than as flat fields.
"""
function protect_main(repo::AbstractString, course)
    owner = course["owner"]
    ghapi("PUT", "/repos/$owner/$repo/branches/main/protection";
          body = """
          {
            "required_status_checks": null,
            "enforce_admins": true,
            "required_pull_request_reviews": {"required_approving_review_count": 0},
            "restrictions": null
          }""",
          hostname = get(course, "hostname", nothing))
    return nothing
end

# Clone the template, replace the template's own values with this group's, and
# push one commit.
#
# The template holds real values rather than placeholders -- its links resolve
# and it can be run -- so this is a substitution of one working project's
# details for another's.
#
# The repository and the package are named independently: the repository is
# `project-1-...` and the package inside it is `Project1`. Julia does not
# require them to agree -- a package is its name and uuid in Project.toml, not
# where it lives -- and only the clone directory follows the repository, which
# is why `cd` has a rule of its own.
#
# Longest strings first: replacing the bare package name before the URLs that
# contain it would destroy them.
function fill_project(repo, package, course)
    owner = course["owner"]
    template = course["template"]                       # "KLU-BADS/ProjectTemplate.jl"
    template_owner, template_repo = split(template, '/')
    template_package = replace(template_repo, r"\.jl$" => "")

    substitutions = [
        clone_url(template_owner, template_repo) => clone_url(owner, repo),
        pages_url(template_owner, template_repo) => pages_url(owner, repo),
        "cd $template_repo"                      => "cd $repo",
        template_package                         => package,
        r"Copyright \(c\) \d{4}"                 => "Copyright (c) $(Libc.strftime("%Y", time()))",
    ]

    mktempdir() do tmp
        work = joinpath(tmp, "work")
        git(`clone --depth 1 $(clone_url(template_owner, template_repo)) $work`)
        rm(joinpath(work, ".git"); recursive = true)

        for (dir, _, files) in walkdir(work), file in files
            path = joinpath(dir, file)
            text = try
                read(path, String)
            catch
                continue                                 # not text; leave it alone
            end
            replaced = replace(text, substitutions...)
            replaced == text || write(path, replaced)
        end

        source = joinpath(work, "src", template_package * ".jl")
        isfile(source) && mv(source, joinpath(work, "src", package * ".jl"))

        left = leftovers(work, template_package)
        isempty(left) ||
            error("$repo: the template's name survives in " * join(left, ", ") *
                  " -- nothing has been pushed")

        git(`init -q -b main`; dir = work)
        git(`add -A`; dir = work)
        git(`commit -q -m "Add project from $template"`; dir = work)
        git(`remote add origin $(clone_url(owner, repo))`; dir = work)
        git(`push -q -u origin main`; dir = work)
    end

    return nothing
end

# Files that still mention the template. With real values rather than
# placeholders, a missed substitution looks plausible instead of obviously
# wrong, so it is checked rather than trusted.
function leftovers(work, template_package)
    found = String[]
    for (dir, _, files) in walkdir(work), file in files
        path = joinpath(dir, file)
        text = try
            read(path, String)
        catch
            continue
        end
        occursin(template_package, text) && push!(found, relpath(path, work))
    end
    return found
end

clone_url(owner, repo) = "https://github.com/$owner/$repo.git"
pages_url(owner, repo) = "https://$(lowercase(owner)).github.io/$repo/"

function git(args::Cmd; dir = nothing)
    cmd = dir === nothing ? `git $args` : `git -C $dir $args`
    out, err = IOBuffer(), IOBuffer()
    try
        run(pipeline(cmd; stdout = out, stderr = err))
    catch
        error("git $(join(args.exec, " ")) failed:\n" * strip(String(take!(err))))
    end
    return strip(String(take!(out)))
end

"""
    invite(email, course)

Invite one email address to the organisation.

Invitations are by email rather than by username, because an email address is
what a lecturer has. The person may not have a GitHub account yet; the
invitation lets them make one and join.
"""
function invite(email::AbstractString, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    require_scopes(["admin:org"]; hostname = host)
    ghapi("POST", "/orgs/$owner/invitations";
          fields = ["email" => email, "role" => "direct_member"],
          hostname = host)
    return nothing
end

"""
    pending_invitations(course)

Return the email addresses of invitations to the organisation that nobody has
accepted yet.
"""
function pending_invitations(course)
    owner = course["owner"]
    return ghlines("/orgs/$owner/invitations", ".[].email // empty";
                   hostname = get(course, "hostname", nothing))
end

"""
    org_members(course)

Return the logins of everyone in the organisation.
"""
function org_members(course)
    owner = course["owner"]
    return ghlines("/orgs/$owner/members", ".[].login";
                   hostname = get(course, "hostname", nothing))
end

"""
    named_members(course)

Return everyone in the organisation as `(login, name, teams)`, sorted by login.

`name` is the account's display name, which can be empty. It is not given by
the members endpoint, so each person is read separately. The public email
address is deliberately not collected: almost nobody publishes one, so the
column would be blank for almost everybody.
"""
function named_members(course)
    host = get(course, "hostname", nothing)
    belongs = team_membership(course)

    people = NamedTuple[]
    for login in org_members(course)
        name = ghapi("GET", "/users/$login"; jq = ".name // \"\"", hostname = host)
        push!(people, (login = login, name = name,
                       teams = get(belongs, login, String[])))
    end
    return sort(people; by = p -> p.login)
end

"""
    team_membership(course)

Return a `login => teams` map for the whole organisation.

Asked team by team rather than person by person: GitHub will say who is in a
team but not which teams somebody is in, and there are fewer teams than
students.
"""
function team_membership(course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    belongs = Dict{String,Vector{String}}()
    for team in ghlines("/orgs/$owner/teams", ".[].slug"; hostname = host)
        for login in ghlines("/orgs/$owner/teams/$team/members", ".[].login"; hostname = host)
            push!(get!(belongs, login, String[]), team)
        end
    end

    for teams in values(belongs)
        sort!(teams)
    end
    return belongs
end
