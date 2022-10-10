module FlexSearch
import Gumbo, JSON, AbstractTrees, NodeJS
import ..walk_outputs

const ID = Ref(0)

mutable struct Fragment
    id::Int
    title::String
    ref::Union{String,Nothing}
    content::String
end

Fragment(ref, title, content) = Fragment(ID[] += 1, title, ref, content)

mutable struct Document
    id::Int
    ref::String
    title::String
    content::Vector{Fragment}
end

Document(ref) = Document(ID[] += 1, ref, "", [])

struct SearchIndex
    documents::Vector{Document}
end

SearchIndex() = SearchIndex([])

is_section_start(el) =
    Gumbo.hasattr(el, "id") && (
        Gumbo.tag(el) in (:h1, :h2, :h3, :h4, :h5, :h6, :h7, :h8) || (
            Gumbo.tag(el) == :a &&
            Gumbo.hasattr(el, "href") &&
            Gumbo.getattr(el, "class", "") == "docstring-binding"
        )
    )

function add_fragment(doc, el)
    ref = nothing
    current = Fragment(ref, doc.title, "")

    for e in AbstractTrees.PreOrderDFS(el)
        if e isa Gumbo.HTMLElement
            if is_section_start(e)
                ref = Gumbo.getattr(e, "id", "")
                text = Gumbo.text(e)
                if !isempty(text)
                    current = Fragment(ref, text, "")
                    push!(doc.content, current)
                end
            elseif isempty(e.children)
                text = Gumbo.text(e)
                if !isempty(text)
                    current.content = string(current.content, ' ', text)
                end
            end
        else
            current.content = string(current.content, ' ', Gumbo.text(e))
        end
    end
end

function add_to_index!(index, ref, file)
    content = read(file, String)
    html = Gumbo.parsehtml(content)

    doc = Document(ref)

    for el in AbstractTrees.PreOrderDFS(html.root)
        if el isa Gumbo.HTMLElement
            if Gumbo.tag(el) == :title
                title = Gumbo.text(el)
                doc.title = first(split(title, " · "))
            end
            if Gumbo.tag(el) == :article && Gumbo.getattr(el, "class", "") == "content"
                add_fragment(doc, el)
                break
            end
        end
    end
    push!(index.documents, doc)
end

function generate_index(root, docs, config)
    search_index = SearchIndex()
    walk_outputs(root, docs, config.index_versions) do path, file
        add_to_index!(search_index, path, file)
    end

    return search_index
end

function inject_script!(custom_scripts)
    pushfirst!(custom_scripts, joinpath("assets", "default", "flexsearch.bundle.js"))
    pushfirst!(custom_scripts, joinpath("assets", "default", "flexsearch_integration.js"))
end

function inject_styles!(custom_styles)
    pushfirst!(custom_styles, joinpath("assets", "default", "flexsearch.css"))
end

function inject_html!(parent)
    div = Gumbo.HTMLElement{:div}([], parent, Dict("class" => "search nav-item"))
    push!(parent.children, div)
    input = Gumbo.HTMLElement{:input}(
        [],
        div,
        Dict("id" => "search-input", "placeholder" => "Search..."),
    )
    push!(div.children, input)
    suggestions = Gumbo.HTMLElement{:ul}(
        [],
        div,
        Dict("id" => "search-result-container", "class" => "suggestions hidden"),
    )
    push!(div.children, suggestions)
    keybinding = Gumbo.HTMLElement{:div}(
        [],
        div,
        Dict("class" => "search-keybinding"),
    )
    push!(keybinding.children, Gumbo.HTMLText(keybinding, "/"))
    push!(div.children, keybinding)
end

function to_json_index(index::SearchIndex, file)
    open(file, "w") do io
        writer = JSON.Writer.CompactContext(io)
        JSON.begin_array(writer)
        serialization = JSON.StandardSerialization()
        for doc in index.documents
            for frag in doc.content
                JSON.delimit(writer)
                JSON.begin_object(writer)
                JSON.show_pair(writer, serialization, "id", frag.id)
                JSON.show_pair(writer, serialization, "pagetitle", doc.title)
                JSON.show_pair(writer, serialization, "title", chomp(frag.title))
                JSON.show_pair(
                    writer,
                    serialization,
                    "ref",
                    string(doc.ref, "/#", frag.ref),
                )
                JSON.show_pair(writer, serialization, "content", frag.content)
                JSON.end_object(writer)
            end
        end
        JSON.end_array(writer)
    end
end

function build_search_index(root, docs, config)
    ID[] = 0
    idx = generate_index(root, docs, config)
    to_json_index(idx, joinpath(root, "index.json"))
    println("Writing flexsearch index:")
    cd(root) do
        run(
            `$(NodeJS.nodejs_cmd()) $(joinpath(@__DIR__, "..", "..", "flexsearch", "gensearch.js"))`,
        )
    end
    return nothing
end
end