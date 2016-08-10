# Set Disk Storage Runbook
# Version 0.8

workflow Set-Disk-Iops
{
    param
    (
        [Parameter(Mandatory=$true)]
        [String] $Name,
        
        [Parameter(Mandatory=$true)]
        [String] $Operation,
        
        [Parameter(Mandatory=$true)]
        [String] $VMMJOBID,
               
        [Parameter(Mandatory=$true)]
        [object] $PARAMS,
        
        [Parameter(Mandatory=$true)]
        [object] $RESOURCEOBJECT
    )

    # Connection to access VMM server.
    $VmmConnection = Get-AutomationConnection -Name 'VmmConnection'
    $VmmServerName = $VmmConnection.ComputerName

    $SecurePassword = ConvertTo-SecureString -AsPlainText -String $VmmConnection.Password -Force
    $VmmCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $VmmConnection.Username, $SecurePassword
    
    # PARAMS to vars USING (Disk Create/Delete)
    if ($name -eq "VMM.VirtualDiskDrive") {
        $DiskIDTemplate = $PARAMS.VirtualHardDiskId  #VHDX Template ID
        $DiskName = $PARAMS.FileName  #New Virtual Disk Name
        $VMID = $PARAMS.VMId # Virtual Machine ID
    }
    
    # PARAMS to vars USING (VM Create/Delete)
    if ($name -eq "VMM.VirtualMachine") {
        if ($Operation -eq "Create") {
            $DiskIDTemplate = "System"  #VHDX ROOT Use only Standard storage
            $VMID = $RESOURCEOBJECT.Id # Virtual Machine ID
        } else { #Delete VM
            $VMID = $PARAMS.Id # Virtual Machine ID  
        }
        write-output vmID_$VMID
    }
    
    # Connection to access MsSQL server.
    $MsSQLCred = Get-AutomationPSCredential -Name 'MsSQL-BillingDB'
    [string] $MsSQLLogin = $MsSQLCred.Username
    $MsSQLPassword = $MsSQLCred.Password
    [string] $MsSQLDatabase = Get-AutomationVariable -Name 'MsSQL-Billing-Database'
    [string] $MsSQLServer = Get-AutomationVariable -Name 'MsSQL-Billing-Server'
    
    #Get iops Defaults
    [string] $iops = Get-AutomationVariable -Name 'iops-defaults'
    
    inlinescript {
        
        Write-output "Start Inline"
        
    	# Import VMM module.
    	Import-Module virtualmachinemanager
       
        # Connect to VMM server.
        Get-SCVMMServer -ComputerName $Using:VmmServerName

        ### VARS DB Settings 
        $SQLserver = $USING:MsSQLServer
        $SQLDatabase = $USING:MsSQLDatabase
        $SQLuser = $USING:MsSQLLogin
        $SQLSecurePassword = $USING:MsSQLPassword
        # We need unsecure password to connect DB
        $SQLBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SQLSecurePassword)
        $SQLUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($SQLBSTR)

        ### MsSQL CONNECTION
        $Connection = New-Object System.Data.SQLClient.SQLConnection
        $Connection.ConnectionString = "Server = '$SQLServer';database='$SQLDatabase'; User ID = '$SQLuser'; Password = '$SQLUnsecurePassword';trusted_connection=true; Integrated Security=false"
        $Connection.Open()
        $Command = New-Object System.Data.SQLClient.SQLCommand
        $Command.Connection = $Connection
        ###

        $job = Get-SCJob -ID $USING:vmmjobid
        
        ## Check Job Status
        
        $JobStatus=$Job.Status
        
        #Wait Until Task Completed
        while ($JobStatus -eq "Running") { 
            write-output "Start Sleep"
            start-sleep 30
            $JobStatus=$Job.Status     
        }
        #Test Job Result
        if ($JobStatus -eq "Failed") {  
            write-output "Job Failed!"
            write-output JOBid:$job.ID
            break    
        }
        
        
        
        function CheckSQLRecord() {
            ## Search Disk if exists in DB
            $query = "SELECT * FROM Disks WHERE DiskID like '"+$DiskID+"'"
            $Command.CommandText = $query
            $reader = $Command.ExecuteReader()
            $Test_SQL = $reader.Read()
            $reader.Close()
            return $Test_SQL
            ###
        }
    
        ## Add Disk to Table SQL
        if ($USING:Operation -eq "Create") {  #Create Disk or VM
            
            write-output "Start Create Disk jobs"
            
            ### iops limit (standard:fast:ultra)
            $iolimit=$USING:iops
            $Qos_STD = $iolimit.Split(":")[0]
            $Qos_Fast = $iolimit.Split(":")[1]
            $Qos_Ultra = $iolimit.Split(":")[2]
            ###
            
            #Universal vars
            $vmID = $USING:VMID #For vmID and VmName
            $VirtualMachine = Get-SCVirtualMachine -id $vmID
            $VmName = $VirtualMachine.Name

            if ($Using:Name -eq "VMM.VirtualDiskDrive") {  #Vars To Create Disk
                #New Disk Name
                write-output "Create Disk Vars"
                [string]$DiskName = $USING:DiskName 
                #Get New Disk Storage Type
                [string]$StorageType = (Get-SCVirtualHardDisk -ID $USING:DiskIDTemplate).Tag  #Standard,fast,ultra
                $VDisk = Get-SCVirtualHardDisk -vm $VirtualMachine | ? name -eq $DiskName
            } else {  #Vars To Create VM
                 write-output "Create VM Vars"
                 $VDisk = Get-SCVirtualMachine -id $vmID | Get-SCVirtualHardDisk
                 write-output ($Vdisk).Count
                 [string]$DiskName = $VDisk.Name+"(root)"
                 [string]$StorageType = $USING:DiskIDTemplate
            }
            
            $DiskID = ($VDisk.ID).ToString()
            write-output vmID:$vmID, DiskID:$DiskID      
            $test_sql = CheckSQLRecord
            
            #Write-Output $test_sql
            
            ### If Disk not found IN DB
            if ($test_sql -eq $false) {
                
                #Job parsing
                $Name = $Job.Name
                $Owner = $Job.Owner
                $Time = $Job.EndTime.ToString()
                $JobID = ($Job.ID).ToString()
        
                write-output "IN CREATE STRING"

                $Command.CommandText = "INSERT INTO Disks (DiskID, DiskName, VMID, VmName, Owner, StorageType, jobid, Date) VALUES ('{0}','{1}','{2}','{3}','{4}','{5}','{6}','{7}')" -f $DiskID, $DiskName, $VmID, $VmName, $Job.Owner, $StorageType, $JobID, $Time
                $Command.ExecuteNonQuery() | out-null    
            } 
    
        #write-output $DiskID, $DiskName, $vmID, $vmName, $Job.Owner, $StorageType, $JobID, $Time, $vhdx_template
        
        #ADD QoS
        
        $Location = $VDisk.Location

        $DiskHost = $VDisk.HostName

        #Start Work (for example, set disk iops)
        write-output "Start setting disk iops"
        
        if ($StorageType -eq "Standard" -OR $StorageType -eq "System") { [int]$iops = $Qos_STD }
        if ($StorageType -eq "Fast") { [int]$iops = $Qos_Fast }
        if ($StorageType -eq "Ultra") { [int]$iops = $Qos_Ultra }
        
        ###What We Will Do With Disk?
        #Set MaxIOPS Limit:
        ########Invoke-Command -ScriptBlock {Get-VMHardDiskDrive -VMName $Args[0] | ? Path -eq $Args[1] | Set-VMHardDiskDrive -MaximumIOPS $Args[2]} -ComputerName  $DiskHost -Credential $USING:VmmCredential -ArgumentList $VMname,$Location,$iops
        ############
        # Other Jobs (May be Disk Migration to Other Storage)
        ############
        }
        
        if ($USING:Operation -eq "Delete" -AND $Using:Name -eq "VMM.VirtualDiskDrive") { #Delete Disk
            ## Delete DISK From Database If Disk was found IN DB
            write-output "Start disk removing from DB"
            #Get Disk ID
            $jobfull = Get-SCJob -job $job -full
            $job_auditrecords = $jobfull.AuditRecords
            $RemovedDisk = $job_auditrecords.ObjectData  | ? ObjectType -eq VirtualHardDisk
            $DiskID = ($RemovedDisk.ID | Select -First 1).ToString()
            ##
            $test_sql = CheckSQLRecord
            Write-Output $test_sql
            
            if ($test_sql -eq $true) {
                #write-output REMOVE $DiskID
                $Command.CommandText = "DELETE FROM Disks WHERE DiskID like '$DiskID'"
                $Command.ExecuteNonQuery() | out-null 
            }
        }
        
        if ($USING:Operation -eq "Delete" -AND $Using:Name -eq "VMM.VirtualMachine") { #Delete VM
            ## Delete All VM records From Database
            write-output "Start VM removing from DB"
            #Write to Event Log
            #Get Disk ID
            #$jobfull = Get-SCJob -job $job -full
            #$job_auditrecords = $jobfull.AuditRecords
            ##
            #write-output REMOVE VM $DiskID
            $vmID = $USING:VMID
            $Command.CommandText = "DELETE FROM Disks WHERE VMID like '$vmID'"
            $Command.ExecuteNonQuery() | out-null 
            
        }
        
    #CLOSE DB Connection
    $Connection.Close()

    } -PSComputerName $VmmServerName -PSCredential $VmmCredential
    
}