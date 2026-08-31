# The interactive front-end.
#
# This file holds no logic. It gathers two answers -- which course, and how
# many groups -- and calls `create`, which is a plain function that could
# equally be called from a script. Anything that decides something belongs
# there, not here.
#
# `REPL.TerminalMenus` is stdlib, so the menu costs no dependency.

using REPL.TerminalMenus

"""
    menu(path = pwd())

Start the coordinator.

`path` is the directory holding `defaults.toml` and `courses/`. Without it, the
current directory is used. Nothing else is consulted.

Asks which course to work on and how many groups to create, shows what it would
do, and asks before doing it.
"""
function menu(path::AbstractString = pwd())
    root = config_root(path)
    println("Configuration: ", root)

    settings = nothing

    while true
        courses = list_courses(root)
        options = [courses; "New course…"; "Show people"; "Quit"]

        choice = request("\nCourse:", RadioMenu(options))

        choice == -1 && return nothing              # ctrl-c or q
        choice == length(options) && return nothing # Quit

        if choice == length(options) - 1             # Show people
            # Organisation-wide, so any course's settings name the same owner.
            settings === nothing && (settings = attempt(() -> load_course(first(courses), root)))
            settings === nothing || attempt(() -> show_people(settings))
            continue
        end

        course = choice == length(options) - 2 ? ask_new_course(root) : courses[choice]
        course === nothing && continue

        show_course(course, root) === :quit && return nothing
    end
end

# What exists for one course, group by group, and the way to add more.
#
# A group is a team and a project repository. The two can disagree: the teams
# for this course were made by hand before any repository existed, and anyone
# with access can rename or delete either at any time. So this screen never
# assumes that groups are 1..n, that a team has a repository, or that a
# repository has a team -- it shows what is there and says what is missing.
function show_course(course, root)
    settings = attempt(() -> load_course(course, root))
    settings === nothing && return nothing

    while true
        projects = attempt(() -> survey(course, root))
        projects === nothing && return nothing

        options = [describe(p) for p in projects]
        push!(options, "Add project(s)", "Send invitations", "Write report", "Back", "Quit")

        choice = request("\n$course:", RadioMenu(options))

        choice == -1 && return nothing                  # ctrl-c or q
        choice == length(options) && return :quit
        choice == length(options) - 1 && return nothing # Back

        if choice < length(options) - 4
            show_project(projects[choice], settings) === :quit && return :quit
        elseif choice == length(options) - 4
            add_project(course, root, projects, settings)
        elseif choice == length(options) - 3
            attempt(() -> send_invitations(course, root, settings))
        else
            file = attempt(() -> write_report(course, root))
            file === nothing || println("\n  written ", file)
        end
    end
end

# One line per group. Whatever is missing is named as missing rather than
# left out, because a gap is the thing you want to see.
function describe(p)
    team = p.team === nothing ? "no group" : p.team
    return string(lpad(p.n, 3), "  ", rpad(p.repo, 42), team)
end

# One group. Which options appear depends on what exists: you cannot delete a
# team that is not there, and there is no point offering to create one twice.
#
# Anything destructive asks first, and answers "No" by default.
function show_project(g, settings)
    while true
        println()
        println("  project: ", project_url(g.repo, settings))
        g.team === nothing || println("  group:   ", team_url(g.team, settings))

        actions = project_actions(g, settings)
        options = [label for (label, _) in actions]
        push!(options, "Back", "Quit")

        choice = request("Project $(g.n):", RadioMenu(options))

        choice == -1 && return nothing                  # ctrl-c or q
        choice == length(options) && return :quit
        choice == length(options) - 1 && return nothing # Back

        attempt(actions[choice][2]) === :quit && return :quit
        return nothing   # what exists has changed; go back and look again
    end
end

# The options for one group, in a fixed order, each paired with what it does.
function project_actions(g, settings)
    actions = Pair{String,Any}[]

    if g.team === nothing
        push!(actions, "Recreate group" => () -> create_group(g.n, settings))
    else
        push!(actions, "Show group members" => () -> show_group_members(g.team, settings))
    end

    return actions
end

# Everyone in one group, with their role, and everything you can do about it.
#
# Membership and role are separate here because they are separate on GitHub:
# changing a role leaves the membership alone. Doing it from a list also means
# you act on somebody you can see, rather than on a name you typed.
function show_group_members(team, settings)
    while true
        people = attempt(() -> members(team, settings))
        people === nothing && return nothing

        options = [describe_member(p) for p in people]
        push!(options, "Add group member…", "Back", "Quit")

        choice = request("\n$team:", RadioMenu(options))

        choice == -1 && return nothing                  # ctrl-c or q
        choice == length(options) && return :quit
        choice == length(options) - 1 && return nothing # Back

        if choice == length(options) - 2
            attempt(() -> add_group_member(team, settings))
        else
            group_member_actions(people[choice], team, settings) === :quit && return :quit
        end
    end
end

function describe_member(p)
    return String(rstrip(string(rpad(p.login, 24), p.role == "maintainer" ? "maintainer" : "")))
end

function group_member_actions(person, team, settings)
    change = person.role == "maintainer" ? "Make ordinary member" : "Make maintainer"
    to = person.role == "maintainer" ? "member" : "maintainer"

    options = [change, "Remove from group", "Back", "Quit"]
    choice = request("\n$(person.login):", RadioMenu(options))

    if choice == 1
        attempt(() -> set_role(team, person.login, to, settings))
    elseif choice == 2
        attempt(() -> destructive("remove $(person.login) from $team",
                                  () -> remove_member(team, person.login, settings)))
    elseif choice == 4
        return :quit
    end
    return nothing
end

function add_group_member(team, settings)
    user = ask_line("GitHub username")
    isempty(user) && return nothing

    add_member(team, user, settings)
    return nothing
end

# Nothing destructive happens without this. "No" is first, so the default
# keystroke leaves everything alone.
function destructive(what, action)
    choice = request("Confirm: $what?", RadioMenu(["No", "Yes"]))
    choice == 2 || return nothing
    return action()
end

# Add projects, filling any gap before extending the sequence.
#
# Numbering is meant to be 1..n with nothing missing, so a project deleted in
# the middle leaves a hole that the next addition fills. Asking for two when
# 1, 2, 4 exist therefore creates 3 and 5, not 5 and 6.
function add_project(course, root, projects, settings)
    add = ask_number_of_projects()
    add === nothing && return nothing

    numbers = next_numbers(projects, add)

    println()
    for n in numbers
        print("  ", expand(settings["naming"]["repo"], settings, n), " … ")
        result = attempt(() -> create_project(n, settings))
        println(result === nothing ? "" : "done")
    end
    return nothing
end

# Invite everybody in the course's invitees.txt who is not already invited.
#
# The file is the list of people who should be there; the organisation is what
# is. Inviting is the difference between the two, so running this again after
# adding a line to the file invites only the new person.
function send_invitations(course, root, settings)
    wanted = invitees(course, root)
    if isempty(wanted)
        println("\n  no invitees.txt in ",
                relpath(course_dir(course, root), root), ", or it is empty")
        return nothing
    end

    already = Set(lowercase.(pending_invitations(settings)))
    to_invite = [address for address in wanted if !(lowercase(address) in already)]

    println()
    for address in wanted
        println("  ", lowercase(address) in already ? "already invited  " : "invite           ",
                address)
    end
    println()

    if isempty(to_invite)
        println("  everybody in invitees.txt has been invited already")
        return nothing
    end

    choice = request("Invite $(length(to_invite)) of $(length(wanted))?",
                     RadioMenu(["No", "Yes"]))
    choice == 2 || return nothing

    println()
    for address in to_invite
        print("  ", address, " … ")
        result = attempt(() -> invite(address, settings))
        println(result === nothing ? "" : "invited")
    end
    return nothing
end

# Who has been invited and who has joined.
#
# The two halves cannot be joined up: once an invitation is accepted it leaves
# the pending list, and GitHub keeps no record of which address became which
# account. So an address that is no longer pending has either been accepted or
# never sent, and the members are listed with their display names because that
# is the only thing that pairs a person with an address.
function show_people(settings)
    println()
    println("  pending invitations:")
    pending = pending_invitations(settings)
    if isempty(pending)
        println("    none")
    else
        for address in pending
            println("    ", address)
        end
    end

    println()
    println("  in the organisation:")
    for person in named_members(settings)
        println("    ", rpad(person.login, 20), rpad(person.name, 24),
                join(person.teams, ", "))
    end
    return nothing
end

# The `add` lowest numbers not already taken, in order.
function next_numbers(projects, add)
    taken = Set(p.n for p in projects)
    numbers = Int[]
    n = 1
    while length(numbers) < add
        n in taken || push!(numbers, n)
        n += 1
    end
    return numbers
end

# Run something that talks to GitHub or reads a course file. On failure, say
# what went wrong and return `nothing`, so that a misconfigured course or a
# network error costs you a menu rather than the session.
function attempt(f)
    try
        return f()
    catch e
        println()
        println(e isa ErrorException ? e.msg : sprint(showerror, e))
        return nothing
    end
end

# Write a new course file, and return its name. `nothing` if either answer was
# left empty.
function ask_new_course(root)
    course = ask_line("Course name (lowercase, hyphens)")
    isempty(course) && return nothing

    cohort = ask_line("Cohort")
    isempty(cohort) && return nothing

    name = "$course-$cohort"
    file = course_file(name, root)

    if isfile(file)
        println("courses/", name, "/course.toml exists already.")
        return name
    end

    mkpath(course_dir(name, root))
    write(file, """
    # One course, one cohort.
    #
    # Everything not named here comes from defaults.toml. To set up next year,
    # copy this file and change the cohort.

    course = "$course"
    cohort = "$cohort"
    """)

    println("Written courses/", name, "/course.toml")
    return name
end

# How many groups. `nothing` if the answer was empty or not a positive number,
# so that the caller can go back to the course menu.
function ask_number_of_projects()
    answer = ask_line("Number of projects to add")
    isempty(answer) && return nothing

    groups = tryparse(Int, answer)
    if groups === nothing || groups < 1
        println("Not a number of projects: ", answer)
        return nothing
    end
    return groups
end

function ask_line(question)
    print(question, ": ")
    line = readline()
    return strip(line)
end
