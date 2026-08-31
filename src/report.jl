# A written record of where every group stood at each deadline.
#
# The report is markdown and is written into the course's own directory, so it
# sits beside the configuration that produced it and is versioned with it.
#
# What makes it worth having is the commit links: each milestone names the last
# commit on `main` before its deadline, so marking is reading a tree at a fixed
# point rather than trusting whatever the repository holds today. Students keep
# working after a deadline; the link does not move.

"""
    last_commit(repo, deadline, course)

Return `(sha, when)` for the last commit on `main` at or before `deadline`, or
`nothing` if there is none.

`deadline` is a local date and time. A commit carries an absolute instant and a
timezone offset that only affects how it is displayed, so the comparison is
made on the instant: the deadline is converted from local time to UTC and
handed to GitHub, which does the selecting.
"""
function last_commit(repo::AbstractString, deadline::DateTime, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    until = Dates.format(local_to_utc(deadline), "yyyy-mm-ddTHH:MM:SSZ")
    found = ghapi("GET", "/repos/$owner/$repo/commits?sha=main&until=$until&per_page=1";
                  jq = ".[0] | .sha + \"|\" + .commit.committer.date",
                  hostname = host)

    isempty(found) && return nothing
    sha, when = split(found, '|'; limit = 2)
    return (sha = String(sha), when = String(when))
end

"""
    local_to_utc(dt)

Read `dt` as a time in this machine's timezone and return the same instant in
UTC.

The system's own timezone database does the work, so a deadline written in
summer and one written in winter each get the offset that actually applied on
that date. `isdst = -1` is what leaves that decision to the system rather than
assuming.
"""
function local_to_utc(dt::DateTime)
    tm = Libc.strptime("%Y-%m-%d %H:%M:%S", Dates.format(dt, "yyyy-mm-dd HH:MM:SS"))
    tm.isdst = -1
    return Dates.unix2datetime(Libc.time(tm))
end

"""
    write_report(name, root)

Write `report.md` into the course's directory and return its path.

One section per project: who is in the group, and where the project stood at
each deadline.
"""
function write_report(name::AbstractString, root::AbstractString)
    course = load_course(name, root)
    owner = course["owner"]

    lines = String[]
    push!(lines, "# $(course["course"]) $(course["cohort"])", "")
    push!(lines, "Generated $(Dates.format(now(), "yyyy-mm-dd HH:MM")) local time.", "")

    for project in survey(name, root)
        push!(lines, "## $(project.repo)", "")
        push!(lines, "[Repository]($(project_url(project.repo, course)))" *
                     (project.team === nothing ? " · no group" :
                      " · [Group]($(team_url(project.team, course)))"), "")

        push!(lines, "### Members", "")
        if project.team === nothing
            push!(lines, "None.", "")
        else
            people = members(project.team, course)
            if isempty(people)
                push!(lines, "None.", "")
            else
                push!(lines, "| login | name | role |", "| --- | --- | --- |")
                for person in people
                    display_name = ghapi("GET", "/users/$(person.login)"; jq = ".name // \"\"",
                                         hostname = get(course, "hostname", nothing))
                    push!(lines, "| $(person.login) | $display_name | $(person.role) |")
                end
                push!(lines, "")
            end
        end

        items = activity(project.repo, course)

        for (milestone, window) in zip(get(course, "milestone", []), windows(course))
            deadline = milestone["deadline"]
            push!(lines, "### $(milestone["title"])", "")
            push!(lines, "Deadline " * Dates.format(deadline, "yyyy-mm-dd HH:MM") *
                         " " * local_zone(deadline) * ".", "")

            commit = last_commit(project.repo, deadline, course)
            if commit === nothing
                push!(lines, "No commit before the deadline.", "")
            else
                url = "https://github.com/$owner/$(project.repo)/tree/$(commit.sha)"
                when = Dates.format(moment(commit.when), "yyyy-mm-dd HH:MM")
                push!(lines, "State at the deadline: [`$(commit.sha[1:7])`]($url), " *
                             "committed $when.", "")
            end

            for (kind, heading, path) in ((:issue, "Issues", "issues"),
                                          (:pull, "Pull Requests", "pull"))
                push!(lines, "**$heading**", "")

                rows = events(items, kind, window)
                if isempty(rows)
                    push!(lines, "None.", "")
                    continue
                end

                push!(lines, "| | title | opened by | activity | when |",
                             "| --- | --- | --- | --- | --- |")
                for row in rows
                    link = "https://github.com/$owner/$(project.repo)/$path/$(row.number)"
                    push!(lines, "| [#$(row.number)]($link) | $(row.title) | $(row.author) | " *
                                 "$(row.activity) | $(Dates.format(row.when, "yyyy-mm-dd HH:MM")) |")
                end
                push!(lines, "")
            end
        end
    end

    file = joinpath(course_dir(name, root), "report.md")
    write(file, join(lines, "\n"))
    return file
end

"""
    local_zone(dt)

Return the name this machine's timezone had at `dt`, such as `CEST` or `CET`.

Taken from the system for that date rather than assumed, so a deadline in
summer and one in winter are each labelled correctly.
"""
function local_zone(dt::DateTime)
    tm = Libc.strptime("%Y-%m-%d %H:%M:%S", Dates.format(dt, "yyyy-mm-dd HH:MM:SS"))
    tm.isdst = -1
    return Libc.strftime("%Z", Libc.time(tm))
end

"""
    activity(repo, course)

Return every issue and pull request in a project as
`(number, title, author, kind, opened, closed, merged)`.

`kind` is `:issue` or `:pull`. `closed` and `merged` are `nothing` while open.

Read in two calls and filtered afterwards rather than asked for per milestone,
because what belongs to a milestone here is decided by when it happened, not by
what anybody assigned it to.
"""
function activity(repo::AbstractString, course)
    owner = course["owner"]
    host = get(course, "hostname", nothing)

    items = NamedTuple[]

    for line in ghlines("/repos/$owner/$repo/issues?state=all", 
                        ".[] | [(.number|tostring), .user.login, (.pull_request != null|tostring), .created_at, (.closed_at // \"\"), .title] | join(\"|\")";
                        hostname = host)
        number, author, is_pull, created, closed, title = split(line, '|'; limit = 6)
        push!(items, (number = parse(Int, number), title = String(title),
                      author = String(author), kind = is_pull == "true" ? :pull : :issue,
                      opened = moment(created), closed = moment(closed), merged = nothing))
    end

    # `merged_at` is not on the issues endpoint, so the pull requests are read
    # again for it: a closed pull request is not necessarily a merged one.
    merged = Dict{Int,Union{Nothing,DateTime}}()
    for line in ghlines("/repos/$owner/$repo/pulls?state=all",
                        ".[] | [(.number|tostring), (.merged_at // \"\")] | join(\"|\")";
                        hostname = host)
        number, at = split(line, '|'; limit = 2)
        merged[parse(Int, number)] = moment(at)
    end

    return [item.kind === :pull ? merge(item, (merged = get(merged, item.number, nothing),)) : item
            for item in items]
end

# GitHub's timestamps are UTC. An empty string means the thing has not happened.
moment(text) = isempty(text) ? nothing : DateTime(chop(String(text)), dateformat"yyyy-mm-ddTHH:MM:SS")

"""
    windows(course)

Return `(title, from, to)` per milestone, in deadline order, as instants in UTC.

A milestone's window runs from the previous milestone's deadline to its own, so
work counts towards the milestone it was done before. The first window has no
beginning: everything up to the first deadline belongs to it.
"""
function windows(course)
    milestones = sort(collect(get(course, "milestone", [])); by = m -> m["deadline"])

    result = NamedTuple[]
    from = DateTime(1970)
    for milestone in milestones
        to = local_to_utc(milestone["deadline"])
        push!(result, (title = milestone["title"], from = from, to = to))
        from = to
    end
    return result
end

# Did it happen inside the window? `nothing` never did.
within(moment, window) =
    moment !== nothing && window.from < moment <= window.to



"""
    events(items, kind, window)

Return what happened to issues, or to pull requests, inside one window.

One row per event rather than per item: an issue opened before one deadline and
closed before the next has happened twice, and belongs in both lists. An item
that did nothing in a window does not appear in it.

A pull request that was closed without being merged is its own kind of event.
Counting it as merged would credit abandoned work; leaving it out would hide
that the work was done and thrown away.
"""
function events(items, kind::Symbol, window)
    rows = NamedTuple[]

    for item in items
        item.kind === kind || continue

        within(item.opened, window) &&
            push!(rows, (number = item.number, title = item.title, author = item.author,
                         activity = "opened", when = item.opened))

        if kind === :pull && item.merged !== nothing
            within(item.merged, window) &&
                push!(rows, (number = item.number, title = item.title, author = item.author,
                             activity = "merged", when = item.merged))
        elseif within(item.closed, window)
            push!(rows, (number = item.number, title = item.title, author = item.author,
                         activity = "closed", when = item.closed))
        end
    end

    return sort(rows; by = row -> row.when)
end

