"""
    CaosDB
CaosDB interface for Julia.
"""
module CaosDB

import HTTP.URIs: escapeuri
import HTTP: request
import EzXML: ElementNode, TextNode, XMLDocument, link!, parsexml, root, elements, attributes

"""
    Connection
Type for managing the connection. Fields:

- baseurl: The base url of your server.
  Example: "https://localhost:8887/playground/"
- cacert: The path to a certificate pem file.
  If left empty no custom certificate will be used.
- cookiestring: The cookiestring which will be set by the login function
  after logging in to caosdb.
- verbose: When set to `true` the underlying curl library will respond more
  verbosively. Can be used for debugging.
- usec: When set to true the c++ library will be used instead of the julia module HTTP
"""
mutable struct Connection
    baseurl::Union{Missing,String}
    cacert::Union{Missing,String}
    cookiestring::Union{Missing,String}
    verbose::Bool
    usec::Bool
end

# Todo:
# add "five" function variables to Connection storing the respective
# put, get, del, etc. function pointers.
# On creation of the Connection object, a switch sets the respective functions.

# abstract type Datatype end
# struct Integer <: Datatype end
# struct Double <: Datatype end
# struct Text <: Datatype end
# struct Datetime <: Datatype end
# struct Date <: Datatype end
# struct Boolean <: Datatype end
# struct Reference <: Datatype end

# abstract type Role end
# abstract type RecordTypeOrRecord <: Role end
# struct RecordType <: RecordTypeOrRecord end
# struct Record <: RecordTypeOrRecord end
# struct Property <: Role end
# struct File <: Role end

mutable struct Entity
    role::String
    id::Union{Missing,Int64}
    name::Union{Missing,String}
    value::Union{Missing,String}
    parents::Vector{Entity}
    properties::Vector{Entity}
    datatype::Union{Missing,String,Entity}
    unit::Union{Missing,String}
    description::Union{Missing,String}
    importance::Union{Missing,String}
end

global ID_COUNTER = 0

function next_id()
    global ID_COUNTER
    ID_COUNTER -= 1
    return ID_COUNTER
end

Entity(role; id=next_id(), name=missing, value=missing,
       parents=Vector{Entity}(), properties=Vector{Entity}(), datatype=missing,
       unit=missing, description=missing, importance=missing) =
Entity(role, id, name, value, parents, properties, datatype, unit, description, importance)

Property(;id=next_id(), name=missing, value=missing, parents=Vector{Entity}(),
         datatype=missing, unit=missing, description=missing, importance=missing) =
Entity("Property"; id=id, name=name, value=value, parents=parents,
       properties=Vector{Entity}(), datatype=datatype, unit=unit,
                                         description=description, importance=importance)

Record(;id=next_id(), name=missing, parents=Vector{Entity}(),
       properties=Vector{Entity}(), description=missing) =
Entity("Record"; id=id, name=name, parents=parents, properties=properties,
                                         description=description)

RecordType(;id=next_id(), name=missing,
           parents=Vector{Entity}(), properties=Vector{Entity}(),
           description=missing) = Entity("RecordType"; id=id, name=name,
                                         parents=parents, properties=properties,
                                         description=description)

"""
    sub2node(subs::Vector{Entity}, name::String, node)
Check whether `subs` has length greater 0.
Afterwards create a new node with given `name`,
create subnodes for each element of `subs`,
finally link the new node to `node`.
"""
function sub2node(subs::Vector{Entity}, name::String, node)
    if (length(subs) > 0)
        parentnode = ElementNode(name)
        for par in subs
            subnode = entity2xml(par)
            link!(parentnode, subnode)
        end
        link!(node, parentnode)
    end
end

"""
    @addnonmissingattribute node entity entfield
Add an attribute to an xml node if it is not missing in the entity.
"""
macro addnonmissingattribute(node, entity, entfield)

    t = esc(Symbol(entity))
    s = Symbol(entfield)
    n = esc(Symbol(node))
    quote
        if (!ismissing($(t).$(s)))
            $(n)[$(entfield)] = $(t).$(s)
        end
    end
end


"""
    xml2str(xml)
Convert an xml node or document to a string.
"""
xml2str(xml) = sprint(print, xml)

"""
    encloseElementNode
Add nodes specified by nodes as subnodes to a new elemend node specified by enclosingElement.
- enclosingElement: Name of the node that encloses the entity. One example is "Insert".
"""
function encloseElementNode(nodes, enclosingElement::String)
    enclosingNode = ElementNode(enclosingElement)
    for node in nodes
        link!(enclosingNode, node)
    end
    
    return(enclosingNode)
end

# encloseElementNode(node, enclosingElement) = encloseElementNode([node], enclosingElement)


"""
    entity2xlm(entity)
Convert an `Entity` instance to XML.
This is needed for passing the XML in the body of the HTTP
request to the server.
"""
function entity2xml(entity::Entity)
    node = ElementNode(entity.role)
    if length(entity.parents) > 0
        for par in entity.parents
            parentnode = ElementNode("Parent")
            if ismissing(par.id)
                error("Parents need an ID")
            end
            
            parentnode["id"] = par.id
            parentnode["name"] = par.name
            link!(node, parentnode)
        end
        
    else
        
    end

    for propel in entity.properties
        propnode = entity2xml(propel)
        link!(node, propnode)
    end
    
    
    # sub2node(entity.parents, "Parents", node)
    # sub2node(entity.properties, "Properties", node)
    @addnonmissingattribute("node", "entity", "name")
    @addnonmissingattribute("node", "entity", "id")
    @addnonmissingattribute("node", "entity", "unit")
    @addnonmissingattribute("node", "entity", "description")
    if (!ismissing(entity.value))
        vlnode = TextNode(entity.value)
        link!(node, vlnode)
    end
    if (!ismissing(entity.datatype))
        # TODO: this is not a good solution yet, because of list types
        if (typeof(entity.datatype) == Entity)
            node["datatype"] = entity.datatype.name
        else
            node["datatype"] = entity.datatype
        end
    end
    return node 
end

"""
    xml2entity(node)
Convert a single node to an entity, possibly
also converting subnodes as Properties or Parents.
"""
function xml2entity(node)
    newent = Entity(node.name)
    for at in attributes(node)
        if at.name == "name"
            newent.name = at.content
        elseif at.name == "description"
            newent.description = at.content
        elseif at.name =="datatype"
            newent.datatype = at.content
        elseif at.name == "importance"
            newent.importance = at.content
        elseif at.name == "id"
            newent.id = parse(Int64, at.content)
        end        
    end

    for el in elements(node)
        if el.name == "Parent"
            push!(newent.parents, xml2entity(el))
        end

        if el.name == "Property"
            push!(newent.properties, xml2entity(el))
        end
    end

    if node.name == "Property"
        newent.value = strip(node.content)
    end
    
    
    return newent
end


"""
    xml2entity(xml)
Convert an xml document to a vector of entities.
"""
function xml2entities(xml)
    # error("not implemented yet")
    doc = parsexml(xml)
    root_node = root(doc)
    if root_node.name != "Response"
        println("Warning: This might be malformed")
    end

    # Iterate over subnodes of response.
    # Records, RecordTypes, Properties and
    # in the future Files will be found and converted.
    container = Vector{Entity}()
    for el in elements(root_node)
        if el.name in ["UserInfo", "Query"]
            # skip
        elseif el.name in ["RecordType", "Record", "Property", "Entity"]
            push!(container, xml2entity(el))
        elseif el.name in ["File"]
            # skip for now
        else
            error("Error: Unknown tag " * el.name)
        end
        

            
    end
    return container
end



# TODO: turn the underscore functions into error checking functions like seen above
#       using a macro.
# _base_login = @errorchecking(_base_login)

# why is this not working: joinpath(@__DIR__, "libcaoslib")

function login(username, password, connection::Connection)

        verbose = 0
        if connection.verbose
            verbose = 2
        end
        
        request("POST", connection.baseurl * "login", [],
                "username="*username*"&password="*password;
                verbose=verbose,
#                require_ssl_verification=false,
                cookies=Dict{String,String}("type" => "ok"))

end

function get(url, connection::Connection)

        verbose = 0
        if connection.verbose
            verbose = 2
        end
        
        resp = request("GET", connection.baseurl * url;
                       verbose=verbose,
                       cookies=Dict{String,String}("type" => "ok"))
        # error checking (HTTP error code) missing
        return String(resp.body)

end

function _delete(url, connection::Connection)

        verbose = 0
        if connection.verbose
            verbose = 2
        end
        
        resp = request("DELETE", connection.baseurl * url;
                       verbose=verbose,
                       cookies=Dict{String,String}("type" => "ok"))
        # error checking (HTTP error code) missing
        return String(resp.body)

end

function put(url, body, connection::Connection)
        verbose = 0
        if connection.verbose
            verbose = 2
        end
        
        resp = request("PUT", connection.baseurl * url, [], body;
                       verbose=verbose,
                       cookies=Dict{String,String}("type" => "ok"))
        # error checking (HTTP error code) missing
        return String(resp.body)

end

function post(url, body, connection::Connection)
    println("---- SEND ----")
    println(parsexml(body))
    println("---- RECV ----")

        verbose = 0
        if connection.verbose
            verbose = 2
        end
        
        resp = request("POST", connection.baseurl * url, [], body;
                       verbose=verbose,
                       cookies=Dict{String,String}("type" => "ok"))
        # error checking (HTTP error code) missing
        println(parsexml(String(resp.body)))
        return String(resp.body)
end


function query(querystring, connection::Connection)
    return xml2entities(get("Entity/?query=" *
                             escapeuri(querystring), connection))
end

entity2querystring(cont::Vector{Entity}) = join([element.name for element in cont], ',')

insert(cont::Vector{Entity}, connection) = post("Entity/", xml2str(encloseElementNode(entity2xml.(cont), "Request")), connection)
update(cont::Vector{Entity}, connection) = put("Entity/", xml2str(encloseElementNode(entity2xml.(cont), "Update")), connection)
retrieve(querystring::String, connection::Connection) = xml2entities(get("Entity/" * querystring, connection))
delete(querystring::String, connection::Connection) = _delete("Entity/" * querystring, connection)

retrieve(cont::Vector{Entity}, connection) = retrieve(entity2querystring(cont), connection)
delete(cont::Vector{Entity}, connection) = delete(entity2querystring(cont), connection)


end
