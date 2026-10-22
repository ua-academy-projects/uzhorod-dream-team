# SSH bridge for Vagrant running in WSL.
# WSL (NAT mode) cannot reach Windows 127.0.0.1, where VirtualBox forwards the
# VM's SSH port. SSH in WSL starts this script on Windows (ProxyCommand):
# it connects to that port and passes bytes between SSH (stdin/stdout) and the VM.
param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][int]$Port
)
$ErrorActionPreference = "Stop"

$client = [System.Net.Sockets.TcpClient]::new($HostName, $Port)
$network = $client.GetStream()
$stdin = [Console]::OpenStandardInput()
$stdout = [Console]::OpenStandardOutput()

# Copy in both directions until one side closes the connection.
$toVm = $stdin.CopyToAsync($network)
$fromVm = $network.CopyToAsync($stdout)
[void][System.Threading.Tasks.Task]::WaitAny(@($toVm, $fromVm))
$client.Close()
