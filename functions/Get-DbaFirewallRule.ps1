function Get-DbaFirewallRule {
    <#
    .SYNOPSIS
        Returns firewall rules for SQL Server instances from the target computer.

    .DESCRIPTION
        Returns firewall rules for SQL Server instances from the target computer.
        As the group and the names of the firewall rules are fixed, this command
        only works for rules created with New-DbaFirewallRule.

        This is basically a wrapper around Get-NetFirewallRule executed at the target computer.
        So this only works if Get-NetFirewallRule works on the target computer.

        The functionality is currently limited. Help to extend the functionality is welcome.

        As long as you can read this note here, there may be breaking changes in future versions.
        So please review your scripts using this command after updating dbatools.

    .PARAMETER SqlInstance
        The target SQL Server instance or instances.

    .PARAMETER Credential
        Credential object used to connect to the Computer as a different user.

    .PARAMETER Type
        Returns firewall rules for the given type(s).
        Valid values are:
            Engine - for the SQL Server instance
            Browser - for the SQL Server Browser
            AllInstance - for all firewall rules on the target computer related to SQL Server
        If this parameter is not used, the firewall rule for the SQL Server instance will be returned
        and in case the instance is listening on a port other than 1433,
        also the firewall rule for the SQL Server Browser will be returned.

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Network, Connection, Firewall
        Author: Andreas Jordan (@JordanOrdix), ordix.de

        Website: https://dbatools.io
        Copyright: (c) 2021 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Get-DbaFirewallRule

    .EXAMPLE
        PS C:\> Get-DbaFirewallRule -SqlInstance SRV1

        Returns the firewall rule for the default instance on SRV1.
        In case the instance is not listening on port 1433, it also returns the firewall rule for the SQL Server Browser.

    .EXAMPLE
        PS C:\> Get-DbaFirewallRule -SqlInstance SRV1\SQL2016 -Type Engine

        Returns only the firewall rule for the instance SQL2016 on SRV1.

    .EXAMPLE
        PS C:\> Get-DbaFirewallRule -SqlInstance SRV1\SQL2016 -Type Browser
        PS C:\> Get-DbaFirewallRule -SqlInstance SRV1 -Type Browser

        Both commands return the firewall rule for the SQL Serer Browser on SRV1.
        As the Browser is not bound to a specific instance, only the computer part of SqlInstance is used.

    .EXAMPLE
        PS C:\> Get-DbaFirewallRule -SqlInstance SRV1\SQL2016 -Type AllInstance

        Returns all firewall rules on the computer SRV1 related to SQL Server.
        The value "AllInstance" only uses the computer name part of SqlInstance.

    #>
    [CmdletBinding()]
    param (
        [parameter(Mandatory, ValueFromPipeline)]
        [DbaInstanceParameter[]]$SqlInstance,
        [PSCredential]$Credential,
        [ValidateSet('Engine', 'Browser', 'AllInstance')]
        [string[]]$Type,
        [switch]$EnableException
    )

    begin {
        $cmdScriptBlock = {
            # This scriptblock will be processed by Invoke-Command2.
            try {
                if (-not (Get-Command -Name Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
                    throw 'The module NetSecurity with the command Get-NetFirewallRule is missing on the target computer, so Get-DbaFirewallRule is not supported.'
                }
                $successful = $true
                $verbose = @( )
                $rules = Get-NetFirewallRule -Group 'SQL Server' -WarningVariable warn -ErrorVariable err -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                if ($warn.Count -gt 0) {
                    $successful = $false
                } else {
                    # Change from an empty System.Collections.ArrayList to $null for better readability
                    $warn = $null
                }
                if ($err.Count -gt 0) {
                    if ($err.Count -eq 1 -and $err[0] -match 'No MSFT_NetFirewallRule objects found') {
                        $verbose += "No objects found. Detailed error message: $($err[0])"
                        $err = $null
                    } else {
                        $successful = $false
                    }
                } else {
                    # Change from an empty System.Collections.ArrayList to $null for better readability
                    $err = $null
                }
                if ($successful) {
                    $verbose += "Get-NetFirewallRule was successful, we have $($rules.Count) rules."
                    $rulesWithDetails = @( )
                    foreach ($rule in $rules) {
                        $rulesWithDetails += [PSCustomObject]@{
                            DisplayName = $rule.DisplayName
                            Name        = $rule.Name
                            Protocol    = ($rule | Get-NetFirewallPortFilter).Protocol
                            LocalPort   = ($rule | Get-NetFirewallPortFilter).LocalPort
                            Program     = ($rule | Get-NetFirewallApplicationFilter).Program
                            Rule        = $rule
                        }
                    }
                }
                [PSCustomObject]@{
                    Successful = $successful
                    Rules      = $rulesWithDetails
                    Verbose    = $verbose
                    Warning    = $warn
                    Error      = $err
                    Exception  = $null
                }
            } catch {
                [PSCustomObject]@{
                    Successful = $false
                    Rules      = $null
                    Verbose    = $null
                    Warning    = $null
                    Error      = $null
                    Exception  = $_
                }
            }
        }
    }

    process {
        foreach ($instance in $SqlInstance) {
            # Get all rules for SQL Server from target computer and filter later
            try {
                Write-Message -Level Debug -Message "Executing Invoke-Command2 with ComputerName = $($instance.ComputerName)."
                $commandResult = Invoke-Command2 -ComputerName $instance.ComputerName -Credential $Credential -ScriptBlock $cmdScriptBlock
                if ($commandResult.Verbose) {
                    foreach ($message in $commandResult.Verbose) {
                        Write-Message -Level Verbose -Message $message
                    }
                }
            } catch {
                Stop-Function -Message "Failed to execute command on $($instance.ComputerName) for instance $($instance.InstanceName)." -Target $instance -ErrorRecord $_ -Continue
            }

            # If command was not successful, just output messages and continue with next SqlInstance
            if (-not $commandResult.Successful) {
                [PSCustomObject]@{
                    ComputerName = $instance.ComputerName
                    Warning      = $commandResult.Warning
                    Error        = $commandResult.Error
                    Exception    = $commandResult.Exception
                    Details      = $commandResult
                } | Select-DefaultView -Property ComputerName, Warning, Error, Exception
                continue
            }

            # Add more information to the rules
            $rules = foreach ($rule in $commandResult.Rules) {
                if ($rule.Name -eq 'SQL Server Browser') {
                    $typeName = 'Browser'
                    $instanceName = $null
                    $sqlInstanceName = $null
                } elseif ($rule.Name -eq 'SQL Server default instance') {
                    $typeName = 'Engine'
                    $instanceName = 'MSSQLSERVER'
                    $sqlInstanceName = $instance.ComputerName
                } else {
                    $typeName = 'Engine'
                    $instanceName = $rule.Name -replace '^SQL Server instance (.+)$', '$1'
                    $sqlInstanceName = $instance.ComputerName + '\' + $instanceName
                }
                [PSCustomObject]@{
                    ComputerName = $instance.ComputerName
                    InstanceName = $instanceName
                    SqlInstance  = $sqlInstanceName
                    DisplayName  = $rule.DisplayName
                    Name         = $rule.Name
                    Type         = $typeName
                    Protocol     = $rule.Protocol
                    LocalPort    = $rule.LocalPort
                    Program      = $rule.Program
                    Rule         = $rule
                    Credential   = $Credential
                }
            }

            # What rules should we output?
            $outputRules = @( )
            if ('AllInstance' -in $Type) {
                Write-Message -Level Verbose -Message 'Returning all rules for target computer'
                $outputRules += $rules
            } elseif ($null -eq $Type) {
                Write-Message -Level Verbose -Message 'Returning rule for instance and maybe for Browser'
                # Get the rule for the instance
                $outputRules += $rules | Where-Object { $_.Type -eq 'Engine' -and $_.InstanceName -eq $instance.InstanceName }
                if ($outputRules.Count -eq 0) {
                    Write-Message -Level Verbose -Message 'No rule found for instance'
                } elseif ($outputRules.LocalPort -eq '1433') {
                    Write-Message -Level Verbose -Message 'No rule for Browser needed'
                } else {
                    $outputRules += $rules | Where-Object { $_.Type -eq 'Browser' }
                }
            } else {
                Write-Message -Level Verbose -Message 'Returning specific rules'
                if ('Engine' -in $Type) {
                    Write-Message -Level Verbose -Message 'Returning rule for instance'
                    $outputRules += $rules | Where-Object { $_.Type -eq 'Engine' -and $_.InstanceName -eq $instance.InstanceName }
                }
                if ('Browser' -in $Type) {
                    Write-Message -Level Verbose -Message 'Returning rule for Browser'
                    $outputRules += $rules | Where-Object { $_.Type -eq 'Browser' }
                }
            }
            $outputRules | Select-DefaultView -Property ComputerName, InstanceName, SqlInstance, DisplayName, Type, Protocol, LocalPort, Program
        }
    }
}