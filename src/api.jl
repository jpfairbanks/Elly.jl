
type HDFSException <: Exception
    message::AbstractString
end

type HDFSClient
    channel::HadoopRpcChannel
    controller::HadoopRpcController
    stub::ClientNamenodeProtocolBlockingStub

    function HDFSClient(host::AbstractString, port::Integer, user::AbstractString)
        channel = HadoopRpcChannel(host, port, user)
        controller = HadoopRpcController(false)
        stub = ClientNamenodeProtocolBlockingStub(channel)

        new(channel, controller, stub)
    end
end

function show(io::IO, clnt::HDFSClient)
    ch = clnt.channel
    user_spec = isempty(ch.user) ? ch.user : "$(ch.user)@"
    println(io, "HDFSClient: hdfs://$(user_spec)$(ch.host):$(ch.port)/")
    println("    id: $(clnt.channel.clnt_id)")
    println("    blocking: true")
    println("    connected: $(isconnected(ch))")
end

function set_debug(clnt::HDFSClient, debug::Bool)
    clnt.controller.debug = debug
end

type HDFSFile
end

type HDFSFileInfo
    kind::Int32
    name::AbstractString
    size::UInt64
    replications::UInt32
    block_sz::UInt64
    owner::AbstractString
    grp::AbstractString
    permissions::UInt32
    last_mod::UInt64
    last_access::UInt64

    HDFSFileInfo(fs::HdfsFileStatusProto) = new(fs.fileType, bytestring(fs.path), 
                    fs.length, fs.block_replication, fs.blocksize,
                    fs.owner, fs.group, fs.permission.perm,
                    fs.modification_time, fs.access_time)
end

function _as_dict(obj, d=Dict{Symbol,Any}())
    for name in names(typeof(obj))
        d[name] = getfield(obj, name)
    end
    d
end

function _walkdir(client::HDFSClient, path::AbstractString, process_entry::Function)
    cont = true
    start_after = UInt8[]
    while cont
        inp = GetListingRequestProto()
        set_field(inp, :src, path)
        set_field(inp, :startAfter, start_after)
        set_field(inp, :needLocation, false)
        resp = getListing(client.stub, client.controller, inp)

        if isfilled(resp, :dirList)
            dir_list = resp.dirList
            if isfilled(dir_list, :partialListing)
                partial_listing = dir_list.partialListing
                for filestatus in partial_listing
                    cont = process_entry(filestatus)
                    (cont == false) && break
                end
                (cont == false) && break
            end
            if isfilled(dir_list, :remainingEntries) && (dir_list.remainingEntries > 0)
                start_after = result[end].data
            else
                cont = false
            end
        else
            cont = false
        end
    end
    nothing
end

function _get_file_info(client::HDFSClient, path::AbstractString)
    inp = GetFileInfoRequestProto()
    set_field(inp, :src, path)
    resp = getFileInfo(client.stub, client.controller, inp)
    isfilled(resp, :fs) ? Nullable{HdfsFileStatusProto}(resp.fs) : Nullable{HdfsFileStatusProto}()
end

function _get_block_locations(client::HDFSClient, path::AbstractString, offset::UInt64=uint64(0), length::UInt64=uint64(0))
    (length == uint64(0)) && (length = uint64(1024))
    inp = GetBlockLocationsRequestProto()
    set_field(inp, :src, path)
    set_field(inp, :offset, offset)
    set_field(inp, :length, length)
    resp = getBlockLocations(client.stub, client.controller, inp)
    isfilled(resp, :locations) ? Nullable{LocatedBlocksProto}(resp.locations) : Nullable{LocatedBlocksProto}()
end

#
# Server defaults
function _get_server_defaults(client::HDFSClient)
    inp = GetServerDefaultsRequestProto()
    resp = getServerDefaults(client.stub, client.controller, inp)
    return resp.serverDefaults
end

hdfs_server_defaults(client::HDFSClient) = _as_dict(_get_server_defaults(client))
hdfs_default_block_size(client::HDFSClient) = _get_server_defaults(client).blockSize
hdfs_default_replication(client::HDFSClient) = _get_server_defaults(client).replication

#
# File System Status
_get_fs_status(client::HDFSClient) = getFsStats(client.stub, client.controller, GetFsStatusRequestProto())

hdfs_status(client::HDFSClient) = _as_dict(_get_fs_status(client))

hdfs_capacity(client::HDFSClient) = _get_fs_status(client).capacity
hdfs_capacity_used(client::HDFSClient) = _get_fs_status(client).used
hdfs_capacity_remaining(client::HDFSClient) = _get_fs_status(client).remaining

#
# File Status
function stat(client::HDFSClient, path::AbstractString)
    fileinfo = _get_file_info(client, path)
    isnull(fileinfo) && throw(HDFSException("Path not found $path"))
    hdfs_file_info = HDFSFileInfo(get(fileinfo))
    hdfs_file_info.name = path
    hdfs_file_info
end

exists(client::HDFSClient, path::AbstractString) = !isnull(_get_file_info(client, path))

isdir(client::HDFSClient, path::AbstractString) = isdir(stat(client, path))
isdir(fileinfo::HDFSFileInfo) = (fileinfo.kind == HdfsFileStatusProto_FileType.IS_DIR)

isfile(client::HDFSClient, path::AbstractString) = isfile(stat(client, path))
isfile(fileinfo::HDFSFileInfo) = (fileinfo.kind == HdfsFileStatusProto_FileType.IS_FILE)

islink(client::HDFSClient, path::AbstractString) = islink(stat(client, path))
islink(fileinfo::HDFSFileInfo) = (fileinfo.kind == HdfsFileStatusProto_FileType.IS_SYMLINK)

filesize(client::HDFSClient, path::AbstractString) = filesize(stat(client, path))
filesize(fileinfo::HDFSFileInfo) = fileinfo.size

filemode(client::HDFSClient, path::AbstractString) = filemode(stat(client, path))
filemode(fileinfo::HDFSFileInfo) = fileinfo.permissions

mtime(client::HDFSClient, path::AbstractString) = mtime(stat(client, path))
mtime(fileinfo::HDFSFileInfo) = fileinfo.last_mod

atime(client::HDFSClient, path::AbstractString) = atime(stat(client, path))
atime(fileinfo::HDFSFileInfo) = fileinfo.last_access

function hdfs_blocks(client::HDFSClient, path::AbstractString, offset::UInt64=uint64(0), length::UInt64=uint64(0))
    blocks = (UInt64,Array)[]
    _locations = _get_block_locations(client, path, offset, length)
    isnull(_locations) && (return blocks)
    locations = get(_locations)
    for block in locations.blocks
        block.corrupt && throw(HDFSException("Corrupt block found at offset $(block.offset)"))
        node_ips = AbstractString[]
        for loc in block.locs
            (loc.adminState == DatanodeInfoProto_AdminState.NORMAL) || continue
            node_id = loc.id
            push!(node_ips, node_id.ipAddr)
        end
        push!(blocks, (block.offset, node_ips))
    end
    blocks
end

function hdfs_set_replication(client::HDFSClient, path::AbstractString, replication::Integer)
    inp = SetReplicationRequestProto()
    set_field(inp, :src, path)
    set_field(inp, :replication, UInt32(replication))

    resp = setReplication(client.stub, client.controller, inp)
    resp.result
end

#
# Disk Usage
function _get_content_summary(client::HDFSClient, path::AbstractString)
    inp = GetContentSummaryRequestProto()
    set_field(inp, :path, path)

    resp = getContentSummary(client.stub, client.controller, inp)
    resp.summary
end

function du(client::HDFSClient, path::AbstractString=".", details::Nullable{Dict{Symbol,Any}}=Nullable{Dict{Symbol,Any}}())
    summary = _get_content_summary(client, path)
    isnull(details) || _as_dict(summary, get(details))
    summary.length
end

#
# File listing
function readdir(client::HDFSClient, path::AbstractString=".", limit::Int=typemax(Int))
    result = AbstractString[]
    _walkdir(client, path, (filestatus)->begin
                push!(result, bytestring(filestatus.path))
                (length(result) < limit)
            end)
    result
end

function mkdir(client::HDFSClient, path::AbstractString, create_parents::Bool=false, mode::UInt32=uint32(0o755))
    inp = MkdirsRequestProto()
    set_field(inp, :src, path)
    set_field(inp, :createParent, create_parents)

    perms = FsPermissionProto()
    set_field(perms, :perm, mode)
    set_field(inp, :masked, perms)

    resp = mkdirs(client.stub, client.controller, inp)
    resp.result
end

function mv(client::HDFSClient, src::AbstractString, dst::AbstractString, overwrite::Bool)
    inp = Rename2RequestProto()
    set_field(inp, :src, src)
    set_field(inp, :dst, dst)
    set_field(ino, :overwriteDest, overwrite)

    rename2(client.stub, client.controller, inp)
    true
end

function mv(client::HDFSClient, src::AbstractString, dst::AbstractString)
    inp = RenameRequestProto()
    set_field(inp, :src, src)
    set_field(inp, :dst, dst)

    resp = rename(client.stub, client.controller, inp)
    resp.result
end

function rm(client::HDFSClient, path::AbstractString, recursive::Bool=false)
    inp = DeleteRequestProto()
    set_field(inp, :src, path)
    set_field(inp, :recursive, recursive)

    resp = delete(client.stub, client.controller, inp)
    resp.result
end

function open()
end
function close()
end
function cp()
end
function pwd()
end
function cd()
end

