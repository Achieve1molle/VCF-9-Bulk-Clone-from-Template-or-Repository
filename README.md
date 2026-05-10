# VCF9 Clone Bulk Virtual Machines

A PowerShell 7 WPF-based utility for bulk cloning virtual machines in a VMware Cloud Foundation / vCenter environment using `VCF.PowerCLI`.

The tool provides a graphical interface for connecting to vCenter, selecting deployment targets, previewing VM names, validating the deployment plan, and executing parallel VM clone jobs with live logging and cancellation support.

## Features

- WPF graphical interface for VM clone planning and execution
- PowerShell 7 support with automatic STA relaunch for WPF compatibility
- Optional local self-signing of the script to improve execution behavior
- vCenter connection and live inventory refresh
- Supports deployment from:
  - vCenter VM templates
  - Content Library items
- Inventory discovery for:
  - Templates
  - Content Library template or OVF items
  - Clusters
  - Datastores
  - Networks / port groups
  - VM folders
  - OS customization specifications
- VM name preview using `<pattern>-###`
- Auto-detection of the next available VM number
- Validation before execution
- Parallel clone execution with configurable batch size from 1 to 6
- Round-robin host placement across connected powered-on hosts in the selected cluster
- Optional CPU and memory override
- Optional OS customization spec for vCenter template deployments
- Live log output in the UI
- Run folder with log and JSON results
- Cancel running clone jobs

## Script Version

The script declares the UI version as:

```powershell
$Global:VCFCloneUiVersion = '1.4'
