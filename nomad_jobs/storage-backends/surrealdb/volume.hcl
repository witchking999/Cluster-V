# SurrealDB database storage volume (Dynamic Host Volume using NFS)
# For volume registration - requires node_id and host_path
type = "host"
name = "surrealdb-data"
node_id = "781790f9-602e-4100-6783-7eeb55db185c"  # angmar (head node where NFS is mounted)
host_path = "/home/shared/surrealdb"
capacity = "10GiB"

capability {
  access_mode = "single-node-writer"
  attachment_mode = "file-system"
}






