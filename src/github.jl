# The only place in this package that talks to GitHub.
#
# Everything goes through the `gh` command line tool, so that this package
# never stores a token: `gh auth login` has already done that. Calls written
# this way read as the REST endpoints they are, which is what makes them
# checkable against GitHub's documentation.
#
# `gh` also does the JSON, in both directions: `--jq` picks fields out of a
# response, `-F` builds a request body. So this package parses no JSON and
# needs no JSON library.
#
# Tests replace `ghapi` with a recorded stand-in, so no test touches the
# network.

"""
    ghapi(method, path; fields = (), jq = nothing, hostname = nothing)

Call the GitHub REST API and return the output as text.

`method` is `"GET"`, `"POST"`, `"PUT"` or `"DELETE"`, `path` is the endpoint
without a leading host, for example `"/orgs/KLU-BADS/teams"`.

`fields` are `name => value` pairs sent as the request body, typed by `gh`, so
`"private" => false` is sent as a boolean. `body` is a JSON string, for the few
endpoints whose body is nested and cannot be written as flat fields. `jq`
selects part of the response.
`hostname` selects a GitHub Enterprise Server instance; `nothing` means
github.com.
"""
function ghapi(method::AbstractString, path::AbstractString;
               fields = (), body = nothing, jq = nothing, hostname = nothing)
    args = String["api",
                  "--method", uppercase(method),
                  "-H", "Accept: application/vnd.github+json",
                  "-H", "X-GitHub-Api-Version: 2022-11-28"]
    for (name, value) in fields
        append!(args, ["-F", "$name=$value"])
    end
    body === nothing || append!(args, ["--input", "-"])
    jq === nothing || append!(args, ["--jq", jq])
    hostname === nothing || append!(args, ["--hostname", hostname])
    push!(args, path)

    out, err = IOBuffer(), IOBuffer()
    command = body === nothing ?
        pipeline(`gh $args`; stdout = out, stderr = err) :
        pipeline(`gh $args`; stdin = IOBuffer(body), stdout = out, stderr = err)

    try
        run(command)
    catch
        message = strip(String(take!(err)))
        error("gh api $(uppercase(method)) $path failed:\n$message")
    end

    return strip(String(take!(out)))
end

"""
    ghlines(path, jq; hostname = nothing)

Call a GitHub endpoint that returns a list and collect one line per item,
following pages.

`gh` 2.45 has `--paginate` but no `--slurp`, so paginating there yields several
JSON documents at once. Asking page by page keeps each response simple.
"""
function ghlines(path::AbstractString, jq::AbstractString;
                 hostname = nothing, per_page::Int = 100)
    lines = String[]
    page = 1
    while true
        sep = occursin('?', path) ? "&" : "?"
        text = ghapi("GET", "$path$(sep)per_page=$per_page&page=$page";
                     jq = jq, hostname = hostname)
        isempty(text) && break

        page_lines = split(text, '\n')
        append!(lines, page_lines)
        length(page_lines) < per_page && break
        page += 1
    end
    return lines
end

"""
    gh_scopes(; hostname = nothing)

Return the OAuth scopes of the token `gh` is currently authenticated with.

Used to fail early with a useful message when a call needs a scope that a
default `gh auth login` does not grant.
"""
function gh_scopes(; hostname = nothing)
    args = String["auth", "status"]
    hostname === nothing || append!(args, ["--hostname", hostname])

    out = IOBuffer()
    try
        run(pipeline(`gh $args`; stdout = out, stderr = out))
    catch
        error("gh auth status failed:\n" * strip(String(take!(out))))
    end

    found = match(r"Token scopes:\s*(.*)", String(take!(out)))
    found === nothing && return String[]

    return [strip(s, [' ', '\'', '"']) for s in split(found.captures[1], ",")]
end

"""
    require_scopes(needed; hostname = nothing)

Stop unless the token `gh` holds has every scope in `needed`.

Checked before the first call of an operation rather than relied on to fail
part way through: creating a project makes a repository, pushes to it, then
creates a group, and a scope missing at the last step would leave the first
two behind.
"""
function require_scopes(needed; hostname = nothing)
    have = gh_scopes(; hostname = hostname)
    missing_scopes = [scope for scope in needed if !(scope in have)]
    isempty(missing_scopes) && return nothing

    error("the GitHub token is missing the scope " *
          join(missing_scopes, " and ") * ".\n" *
          "Grant it with:  gh auth refresh -h " *
          (hostname === nothing ? "github.com" : hostname) *
          " -s " * join(missing_scopes, ","))
end

"""
    gh_login(; hostname = nothing)

Return the login of the account `gh` is authenticated as.
"""
function gh_login(; hostname = nothing)
    return ghapi("GET", "/user"; jq = ".login", hostname = hostname)
end

