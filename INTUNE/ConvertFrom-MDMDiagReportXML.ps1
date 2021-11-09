﻿function ConvertFrom-MDMDiagReportXML {
    <#
    .SYNOPSIS
    Function for converting Intune XML report generated by MdmDiagnosticsTool.exe to a PowerShell object.

    .DESCRIPTION
    Function for converting Intune XML report generated by MdmDiagnosticsTool.exe to a PowerShell object.
    There is also option to generate HTML report instead.

    .PARAMETER MDMDiagReport
    Path to MDMDiagReport.xml.

    If not specified, new report will be generated and used.

    .PARAMETER asHTML
    Switch for outputting results as a HTML page instead of PowerShell object.
    PSWriteHtml module is required!

    .PARAMETER HTMLReportPath
    Path to html file where HTML report should be stored.

    Default is '<yourUserProfile>\IntuneReport.html'.

    .PARAMETER showEnrollmentIDs
    Switch for adding EnrollmentID property i.e. property containing Enrollment ID of given policy.
    From my point of view its useless :).

    .PARAMETER showURLs
    Switch for adding PolicyURL and PolicySettingsURL properties i.e. properties containing URL with Microsoft documentation for given CSP.

    Make running the function slower! Because I test each URL and shows just existing ones.

    .EXAMPLE
    $intuneReport = ConvertFrom-MDMDiagReportXML
    $intuneReport | Out-GridView

    Generates new Intune report, converts it into PowerShell object and output it using Out-GridView.

    .EXAMPLE
    ConvertFrom-MDMDiagReportXML -asHTML -showURLs

    Generates new Intune report (policies documentation URL included), converts it into HTML web page and opens it.

    .NOTES
    Author: Ondrej Sebela (ztrhgf@seznam.cz)
    #>

    [CmdletBinding()]
    param (
        [ValidateScript( {
                if ($_ -match "\.xml$") {
                    $true
                } else {
                    throw "$_ is not a valid path to MDM xml report"
                }
            })]
        [string] $MDMDiagReport,

        [switch] $asHTML,

        [ValidateScript( {
                if ($_ -match "\.html$") {
                    $true
                } else {
                    throw "$_ is not a valid path to html file. Enter something like 'C:\destination\intune.html'"
                }
            })]
        [string] $HTMLReportPath = (Join-Path $env:USERPROFILE "IntuneReport.html"),

        [switch] $showEnrollmentIDs,

        [switch] $showURLs
    )

    if ($asHTML) {
        # array of results that will be in the end transformed into HTML report
        $results = @()

        if (!(Get-Module 'PSWriteHtml') -and (!(Get-Module 'PSWriteHtml' -ListAvailable))) {
            throw "Module PSWriteHtml is missing. To get it use command: Install-Module PSWriteHtml -Scope CurrentUser"
        }

        # create parent directory if not exists
        [Void][System.IO.Directory]::CreateDirectory((Split-Path $HTMLReportPath -Parent))
    }

    if (!$MDMDiagReport) {
        ++$reportNotSpecified
        $MDMDiagReport = "$env:PUBLIC\Documents\MDMDiagnostics\MDMDiagReport.xml"
    }

    $MDMDiagReportFolder = Split-Path $MDMDiagReport -Parent

    # generate XML report if necessary
    if ($reportNotSpecified) {
        Write-Verbose "Generating '$MDMDiagReport'..."
        Start-Process MdmDiagnosticsTool.exe -Wait -ArgumentList "-out `"$MDMDiagReportFolder`"" -NoNewWindow
    }
    if (!(Test-Path $MDMDiagReport -PathType Leaf)) {
        Write-Verbose "'$MDMDiagReport' doesn't exist, generating..."
        Start-Process MdmDiagnosticsTool.exe -Wait -ArgumentList "-out `"$MDMDiagReportFolder`"" -NoNewWindow
    }

    Write-Verbose "Converting '$MDMDiagReport' to XML object"
    [xml]$xml = Get-Content $MDMDiagReport -Raw -ErrorAction Stop

    $userEnrollmentID = Get-ScheduledTask -TaskName "*pushlaunch*" -TaskPath "\Microsoft\Windows\EnterpriseMgmt\*" | Select-Object -ExpandProperty TaskPath | Split-Path -Leaf
    Write-Verbose "Your EnrollmentID is $userEnrollmentID"

    #region helper functions

    function Test-URLStatus {
        param ($URL)

        try {
            $response = [System.Net.WebRequest]::Create($URL).GetResponse()
            $status = $response.StatusCode
            $response.Close()
            if ($status -eq 'OK') { return $true } else { return $false }
        } catch {
            return $false
        }
    }

    function _translateStatus {
        param ([int] $statusCode)

        $statusMessage = ""

        switch ($statusCode) {
            '10' { $statusMessage = "Initialized" }
            '20' { $statusMessage = "Download In Progress" }
            '25' { $statusMessage = "Pending Download Retry" }
            '30' { $statusMessage = "Download Failed" }
            '40' { $statusMessage = "Download Completed" }
            '48' { $statusMessage = "Pending User Session" }
            '50' { $statusMessage = "Enforcement In Progress" }
            '55' { $statusMessage = "Pending Enforcement Retry" }
            '60' { $statusMessage = "Enforcement Failed" }
            '70' { $statusMessage = "Enforcement Completed" }
            default { $statusMessage = $statusCode }
        }

        return $statusMessage
    }
    #endregion helper functions

    if ($showURLs) {
        $clientIsOnline = Test-URLStatus 'https://google.com'
    }

    #region enrollments
    Write-Verbose "Getting Enrollments (MDMEnterpriseDiagnosticsReport.Resources.Enrollment)"
    $enrollment = $xml.MDMEnterpriseDiagnosticsReport.Resources.Enrollment | % { ConvertFrom-XML $_ }

    if ($enrollment) {
        Write-Verbose "Processing Enrollments"

        $enrollment | % {
            <#
            <Resources>
                <Enrollment>
                    <EnrollmentID>5AFCD0A0-321F-4635-B3EB-2EBD28A0FD9A</EnrollmentID>
                    <Scope>
                    <ResourceTarget>device</ResourceTarget>
                    <Resources>
                        <Type>default</Type>
                        <ResourceName>./device/Vendor/MSFT/DeviceManageability/Provider/WMI_Bridge_Server</ResourceName>
                        <ResourceName>2</ResourceName>
                        <ResourceName>./device/Vendor/MSFT/VPNv2/K_AlwaysOn_VPN</ResourceName>
                    </Resources>
                    </Scope>
            #>
            $policy = $_
            $enrollmentId = $_.EnrollmentId

            $policy.Scope | % {
                $policyScope = $_.ResourceTarget -replace "device", "Device"

                foreach ($policyAreaName in $_.Resources.ResourceName) {
                    # some policies have just number instead of any name..I don't know what it means so I ignore them
                    if ($policyAreaName -match "^\d+$") {
                        continue
                    }
                    # get rid of MSI installations (I have them with details in separate section)
                    if ($policyAreaName -match "device/Vendor/MSFT/EnterpriseDesktopAppManagement/MSI") {
                        continue
                    }
                    # get rid of useless data
                    if ($policyAreaName -match "device/Vendor/MSFT/DeviceManageability/Provider/WMI_Bridge_Server") {
                        continue
                    }

                    Write-Verbose "`nEnrollment '$enrollmentId' applied to '$policyScope' configures resource '$policyAreaName'"

                    #region get policy settings details
                    $settingDetails = $null
                    #TODO zjistit co presne to nastavuje
                    # - policymanager.configsource.policyscope.Area

                    <#
                    <ErrorLog>
                        <Component>ConfigManager</Component>
                        <SubComponent>
                            <Name>BitLocker</Name>
                            <Error>-2147024463</Error>
                            <Metadata1>CmdType_Set</Metadata1>
                            <Metadata2>./Device/Vendor/MSFT/BitLocker/RequireDeviceEncryption</Metadata2>
                            <Time>2021-09-23 07:07:05.463</Time>
                        </SubComponent>
                    #>
                    Write-Verbose "Getting Errors (MDMEnterpriseDiagnosticsReport.Diagnostics.ErrorLog)"
                    # match operator used for metadata2 because for example WIFI networks are saved there as ./Vendor/MSFT/WiFi/Profile/<wifiname> instead of ./Vendor/MSFT/WiFi/Profile
                    foreach ($errorRecord in $xml.MDMEnterpriseDiagnosticsReport.Diagnostics.ErrorLog) {
                        $component = $errorRecord.component
                        $errorRecord.subComponent | % {
                            $subComponent = $_

                            if ($subComponent.name -eq $policyAreaName -or $subComponent.Metadata2 -match [regex]::Escape($policyAreaName)) {
                                $settingDetails = $subComponent | Select-Object @{n = 'Component'; e = { $component } }, @{n = 'SubComponent'; e = { $subComponent.Name } }, @{n = 'SettingName'; e = { $policyAreaName } }, Error, @{n = 'Time'; e = { Get-Date $subComponent.Time } }
                                break
                            }
                        }
                    }

                    if (!$settingDetails) {
                        # try more "relaxed" search
                        if ($policyAreaName -match "/") {
                            # it is just common setting, try to find it using last part of the policy name
                            $policyAreaNameID = ($policyAreaName -split "/")[-1]
                            Write-Verbose "try to find just ID part ($policyAreaNameID) of the policy name in MDMEnterpriseDiagnosticsReport.Diagnostics.ErrorLog"
                            # I don't search substring of policy name in Metadata2 because there can be multiple similar policies (./user/Vendor/MSFT/VPNv2/VPN_Backup vs ./device/Vendor/MSFT/VPNv2/VPN_Backup)
                            foreach ($errorRecord in $xml.MDMEnterpriseDiagnosticsReport.Diagnostics.ErrorLog) {
                                $component = $errorRecord.component
                                $errorRecord.subComponent | % {
                                    $subComponent = $_

                                    if ($subComponent.name -eq $policyAreaNameID) {
                                        $settingDetails = $subComponent | Select-Object @{n = 'Component'; e = { $component } }, @{n = 'SubComponent'; e = { $subComponent.Name } }, @{n = 'SettingName'; e = { $policyAreaName } }, Error, @{n = 'Time'; e = { Get-Date $subComponent.Time } }
                                        break
                                    }
                                }
                            }
                        } else {
                            Write-Verbose "'$policyAreaName' doesn't contains '/'"
                        }

                        if (!$settingDetails) {
                            Write-Verbose "No additional data was found for '$policyAreaName' (it means it was successfully applied)"
                        }
                    }
                    #endregion get policy settings details

                    # get CSP policy URL if available
                    if ($showURLs) {
                        if ($policyAreaName -match "/") {
                            $pName = ($policyAreaName -split "/")[-2]
                        } else {
                            $pName = $policyAreaName
                        }
                        $policyURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/$pName-csp"
                        # check that URL exists
                        if ($clientIsOnline) {
                            if (!(Test-URLStatus $policyURL)) {
                                # URL doesn't exist
                                if ($policyAreaName -match "/") {
                                    # sometimes name of the CSP is not second from the end but third
                                    $pName = ($policyAreaName -split "/")[-3]
                                    $policyURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/$pName-csp"
                                    if (!(Test-URLStatus $policyURL)) {
                                        $policyURL = $null
                                    }
                                } else {
                                    $policyURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/policy-csp-$pName"
                                    if (!(Test-URLStatus $policyURL)) {
                                        $policyURL = $null
                                    }
                                }
                            }
                        }
                    }

                    #region return retrieved data
                    $property = [ordered] @{
                        Scope          = $policyScope
                        PolicyName     = $policyAreaName
                        SettingName    = $policyAreaName
                        SettingDetails = $settingDetails
                    }
                    if ($showEnrollmentIDs) { $property.EnrollmentId = $enrollmentId }
                    if ($showURLs) { $property.PolicyURL = $policyURL }
                    $result = New-Object -TypeName PSObject -Property $property

                    if ($asHTML) {
                        $results += $result
                    } else {
                        $result
                    }
                    #endregion return retrieved data
                }
            }
        }
    }
    #endregion enrollments

    #region policies
    Write-Verbose "Getting Policies (MDMEnterpriseDiagnosticsReport.PolicyManager.ConfigSource)"
    $policyManager = $xml.MDMEnterpriseDiagnosticsReport.PolicyManager.ConfigSource | % { ConvertFrom-XML $_ }
    # filter out useless knobs
    $policyManager = $policyManager | ? { $_.policyScope.Area.PolicyAreaName -ne 'knobs' }

    if ($policyManager) {
        Write-Verbose "Processing Policies"

        # get policies metadata
        Write-Verbose "Getting Policies Area metadata (MDMEnterpriseDiagnosticsReport.PolicyManager.AreaMetadata)"
        $policyAreaNameMetadata = $xml.MDMEnterpriseDiagnosticsReport.PolicyManager.AreaMetadata
        # get admx policies metadata
        # there are duplicities, so pick just last one
        Write-Verbose "Getting Policies ADMX metadata (MDMEnterpriseDiagnosticsReport.PolicyManager.IngestedAdmxPolicyMetadata)"
        $admxPolicyAreaNameMetadata = $xml.MDMEnterpriseDiagnosticsReport.PolicyManager.IngestedAdmxPolicyMetadata | Select-Object -Last 1 | % { ConvertFrom-XML $_ }

        Write-Verbose "Getting Policies winning provider (MDMEnterpriseDiagnosticsReport.PolicyManager.CurrentPolicies.CurrentPolicyValues)"
        $winningProviderPolicyAreaNameMetadata = $xml.MDMEnterpriseDiagnosticsReport.PolicyManager.CurrentPolicies.CurrentPolicyValues | % {
            $_.psobject.properties | ? { $_.Name -Match "_WinningProvider$" } | Select-Object Name, Value
        }

        $policyManager | % {
            $policy = $_
            $enrollmentId = $_.EnrollmentId

            $policy.policyScope | % {
                $policyScope = $_.PolicyScope -replace "device", "Device"
                $_.Area | % {
                    <#
                    <ConfigSource>
                        <EnrollmentId>AB068787-67D2-4F7C-AA87-A9127A87411F</EnrollmentId>
                        <PolicyScope>
                            <PolicyScope>Device</PolicyScope>
                            <Area>
                                <PolicyAreaName>BitLocker</PolicyAreaName>
                                <AllowWarningForOtherDiskEncryption>0</AllowWarningForOtherDiskEncryption>
                                <AllowWarningForOtherDiskEncryption_LastWrite>1</AllowWarningForOtherDiskEncryption_LastWrite>
                                <RequireDeviceEncryption>1</RequireDeviceEncryption>
                    #>

                    $policyAreaName = $_.PolicyAreaName
                    Write-Verbose "`nEnrollment '$enrollmentId' applied to '$policyScope' configures area '$policyAreaName'"
                    $policyAreaSetting = $_ | Select-Object -Property * -ExcludeProperty 'PolicyAreaName', "*_LastWrite"
                    $policyAreaSettingName = $policyAreaSetting | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty name
                    if ($policyAreaSettingName.count -eq 1 -and $policyAreaSettingName -eq "*") {
                        # bug? when there is just PolicyAreaName and none other object than probably because of exclude $policyAreaSettingName instead of be null returns one empty object '*'
                        $policyAreaSettingName = $null
                        $policyAreaSetting = $null
                    }

                    #region get policy settings details
                    $settingDetails = @()

                    if ($policyAreaSetting) {
                        Write-Verbose "`tIt configures these settings:"

                        # $policyAreaSetting is object, so I have to iterate through its properties
                        foreach ($setting in $policyAreaSetting.PSObject.Properties) {
                            $settingName = $setting.Name
                            $settingValue = $setting.Value

                            # PolicyAreaName property was already picked up so now I will ignore it
                            if ($settingName -eq "PolicyAreaName") { continue }

                            Write-Verbose "`t`t- $settingName ($settingValue)"

                            # makes test of url slow
                            # if ($clientIsOnline) {
                            #     if (!(Test-URLStatus $policyDetailsURL)) {
                            #         # URL doesn't exist
                            #         $policyDetailsURL = $null
                            #     }
                            # }

                            if ($showURLs) {
                                if ($policyAreaName -match "~Policy~OneDriveNGSC") {
                                    # doesn't have policy csp url
                                    $policyDetailsURL = $null
                                } else {
                                    $policyDetailsURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/policy-csp-$policyAreaName#$(($policyAreaName).tolower())-$(($settingName).tolower())"
                                }
                            }

                            # define base object
                            $property = [ordered]@{
                                "SettingName"     = $settingName
                                "Value"           = $settingValue
                                "DefaultValue"    = $null
                                "PolicyType"      = '*unknown*'
                                "RegKey"          = '*unknown*'
                                "RegValueName"    = '*unknown*'
                                "SourceAdmxFile"  = $null
                                "WinningProvider" = $null
                            }
                            if ($showURLs) { $property.PolicyDetailsURL = $policyDetailsURL }

                            $additionalData = $policyAreaNameMetadata | ? PolicyAreaName -EQ $policyAreaName | Select-Object -ExpandProperty PolicyMetadata | ? PolicyName -EQ $settingName | Select-Object PolicyType, Value, RegKeyPathRedirect, RegValueNameRedirect

                            if ($additionalData) {
                                Write-Verbose "Additional data for '$settingName' was found in policyAreaNameMetadata"
                                <#
                                <PolicyMetadata>
                                    <PolicyName>RecoveryEnvironmentAuthentication</PolicyName>
                                    <Behavior>49</Behavior>
                                    <highrange>2</highrange>
                                    <lowrange>0</lowrange>
                                    <mergealgorithm>3</mergealgorithm>
                                    <policytype>4</policytype>
                                    <RegKeyPathRedirect>Software\Policies\Microsoft\WinRE</RegKeyPathRedirect>
                                    <RegValueNameRedirect>WinREAuthenticationRequirement</RegValueNameRedirect>
                                    <value>0</value>
                                </PolicyMetadata>
                                #>
                                $property.DefaultValue = $additionalData.Value
                                $property.PolicyType = $additionalData.PolicyType
                                $property.RegKey = $additionalData.RegKeyPathRedirect
                                $property.RegValueName = $additionalData.RegValueNameRedirect
                            } else {
                                # no additional data was found in policyAreaNameMetadata
                                # trying to get them from admxPolicyAreaNameMetadata

                                <#
                                <IngestedADMXPolicyMetaData>
                                    <EnrollmentId>11120759-7CE3-4683-AB59-46C27FF40D35</EnrollmentId>
                                    <AreaName>
                                        <ADMXIngestedAreaName>OneDriveNGSCv2~Policy~OneDriveNGSC</ADMXIngestedAreaName>
                                        <PolicyMetadata>
                                            <PolicyName>BlockExternalSync</PolicyName>
                                            <SourceAdmxFile>OneDriveNGSCv2</SourceAdmxFile>
                                            <Behavior>224</Behavior>
                                            <MergeAlgorithm>3</MergeAlgorithm>
                                            <RegKeyPathRedirect>SOFTWARE\Policies\Microsoft\OneDrive</RegKeyPathRedirect>
                                            <RegValueNameRedirect>BlockExternalSync</RegValueNameRedirect>
                                            <PolicyType>1</PolicyType>
                                            <AdmxMetadataDevice>30313D0100000000323D000000000000</AdmxMetadataDevice>
                                        </PolicyMetadata>
                                #>
                                $additionalData = ($admxPolicyAreaNameMetadata.AreaName | ? { $_.ADMXIngestedAreaName -eq $policyAreaName }).PolicyMetadata | ? { $_.PolicyName -EQ $settingName }

                                if ($additionalData) {
                                    Write-Verbose "Additional data for '$settingName' was found in admxPolicyAreaNameMetadata"
                                    $property.PolicyType = $additionalData.PolicyType
                                    $property.RegKey = $additionalData.RegKeyPathRedirect
                                    $property.RegValueName = $additionalData.RegValueNameRedirect
                                    $property.SourceAdmxFile = $additionalData.SourceAdmxFile
                                } else {
                                    Write-Verbose "No additional data found for $settingName"
                                }
                            }

                            $winningProvider = $winningProviderPolicyAreaNameMetadata | ? Name -EQ "$settingName`_WinningProvider" | Select-Object -ExpandProperty Value
                            if ($winningProvider) {
                                if ($winningProvider -eq $userEnrollmentID) {
                                    $winningProvider = 'Intune'
                                }

                                $property.WinningProvider = $winningProvider
                            }

                            $settingDetails += New-Object -TypeName PSObject -Property $property
                        }
                    } else {
                        Write-Verbose "`tIt doesn't contain any settings"
                    }
                    #endregion get policy settings details

                    # get CSP policy URL if available
                    if ($showURLs) {
                        if ($policyAreaName -match "/") {
                            $pName = ($policyAreaName -split "/")[-2]
                        } else {
                            $pName = $policyAreaName
                        }
                        $policyURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/$pName-csp"
                        # check that URL exists
                        if ($clientIsOnline) {
                            if (!(Test-URLStatus $policyURL)) {
                                # URL doesn't exist
                                if ($policyAreaName -match "/") {
                                    # sometimes name of the CSP is not second from the end but third
                                    $pName = ($policyAreaName -split "/")[-3]
                                    $policyURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/$pName-csp"
                                    if (!(Test-URLStatus $policyURL)) {
                                        $policyURL = $null
                                    }
                                } else {
                                    $policyURL = "https://docs.microsoft.com/en-us/windows/client-management/mdm/policy-csp-$pName"
                                    if (!(Test-URLStatus $policyURL)) {
                                        $policyURL = $null
                                    }
                                }
                            }
                        }
                    }

                    #region return retrieved data
                    $property = [ordered] @{
                        Scope          = $policyScope
                        PolicyName     = $policyAreaName
                        SettingName    = $policyAreaSettingName
                        SettingDetails = $settingDetails
                    }
                    if ($showEnrollmentIDs) { $property.EnrollmentId = $enrollmentId }
                    if ($showURLs) { $property.PolicyURL = $policyURL }
                    $result = New-Object -TypeName PSObject -Property $property

                    if ($asHTML) {
                        $results += $result
                    } else {
                        $result
                    }
                    #endregion return retrieved data
                }
            }
        }
    }
    #endregion policies

    #region installations
    Write-Verbose "Getting MSI installations (MDMEnterpriseDiagnosticsReport.EnterpriseDesktopAppManagementinfo.MsiInstallations.TargetedUser.Package)"
    $installation = $xml.MDMEnterpriseDiagnosticsReport.EnterpriseDesktopAppManagementinfo.MsiInstallations.TargetedUser.Package | % { ConvertFrom-XML $_ }
    if ($installation) {
        Write-Verbose "Processing MSI installations"

        $settingDetails = @()

        $installation | % {
            <#
            <MsiInstallations>
                <TargetedUser>
                <UserSid>S-0-0-00-0000000000-0000000000-000000000-000</UserSid>
                <Package>
                    <Type>MSI</Type>
                    <Details>
                    <PackageId>{23170F69-40C1-2702-1900-000001000000}</PackageId>
                    <DownloadInstall>Ready</DownloadInstall>
                    <ProductCode>{23170F69-40C1-2702-1900-000001000000}</ProductCode>
                    <ProductVersion>19.00.00.0</ProductVersion>
                    <ActionType>1</ActionType>
                    <Status>70</Status>
                    <JobStatusReport>1</JobStatusReport>
                    <LastError>0</LastError>
                    <BITSJobId></BITSJobId>
                    <DownloadLocation></DownloadLocation>
                    <CurrentDownloadUrlIndex>0</CurrentDownloadUrlIndex>
                    <CurrentDownloadUrl></CurrentDownloadUrl>
                    <FileHash>A7803233EEDB6A4B59B3024CCF9292A6FFFB94507DC998AA67C5B745D197A5DC</FileHash>
                    <CommandLine>ALLUSERS=1</CommandLine>
                    <AssignmentType>1</AssignmentType>
                    <EnforcementTimeout>30</EnforcementTimeout>
                    <EnforcementRetryIndex>0</EnforcementRetryIndex>
                    <EnforcementRetryCount>5</EnforcementRetryCount>
                    <EnforcementRetryInterval>3</EnforcementRetryInterval>
                    <LocURI>./Device/Vendor/MSFT/EnterpriseDesktopAppManagement/MSI/{23170F69-40C1-2702-1900-000001000000}/DownloadInstall</LocURI>
                    <ServerAccountID>11120759-7CE3-4683-FB59-46C27FF40D35</ServerAccountID>
                    </Details>
            #>
            $type = $_.type
            $details = $_.details

            $details | % {
                Write-Verbose "`t$($_.PackageId) of type $type"

                # define base object
                $property = [ordered]@{
                    "Type"           = $type
                    "Status"         = _translateStatus $_.Status
                    "LastError"      = $_.LastError
                    "PackageId"      = $_.PackageId -replace "{" -replace "}"
                    "ProductVersion" = $_.ProductVersion
                    "CommandLine"    = $_.CommandLine
                    "RetryIndex"     = $_.EnforcementRetryIndex
                    "MaxRetryCount"  = $_.EnforcementRetryCount
                }
                $settingDetails += New-Object -TypeName PSObject -Property $property
            }
        }

        #region return retrieved data
        $property = [ordered] @{
            #FIXME UserSid S-0-0-00-0000000000-0000000000-000000000-000 is device scope, otherwise it is a user!
            Scope          = 'Device' # made up!
            PolicyName     = "SoftwareInstallation" # made up!
            SettingName    = "MSI" # made up!
            SettingDetails = $settingDetails
        }
        if ($showEnrollmentIDs) { $property.EnrollmentId = $null }
        if ($showURLs) { $property.PolicyURL = $null } # this property only to have same properties for all returned objects
        $result = New-Object -TypeName PSObject -Property $property

        if ($asHTML) {
            $results += $result
        } else {
            $result
        }
        #endregion return retrieved data
    }
    #endregion installations

    #region convert results to HTML and output
    if ($asHTML -and $results) {
        Write-Verbose "Converting to HTML"

        # split the results
        $resultsWithSettings = @()
        $resultsWithoutSettings = @()
        $results | % {
            if ($_.settingDetails) {
                $resultsWithSettings += $_
            } else {
                $resultsWithoutSettings += $_
            }
        }

        New-HTML -TitleText "Intune Report" -Online -FilePath $HTMLReportPath -ShowHTML {
            # it looks better to have headers and content in center
            New-HTMLTableStyle -TextAlign center

            New-HTMLSection -HeaderText 'Intune Report' -Direction row -HeaderBackGroundColor Black -HeaderTextColor White -HeaderTextSize 20 {
                if ($resultsWithoutSettings) {
                    New-HTMLSection -HeaderText "Policies without settings details" -HeaderTextAlignment left -CanCollapse -BackgroundColor DeepSkyBlue -HeaderBackGroundColor DeepSkyBlue -HeaderTextSize 10 -HeaderTextColor EgyptianBlue -Direction row {
                        #region prepare data
                        # exclude some not significant or needed properties
                        # SettingName is empty (or same as PolicyName)
                        # settingDetails is empty
                        $excludeProperty = @('SettingName', 'SettingDetails')
                        if (!$showEnrollmentIDs) { $excludeProperty += 'EnrollmentId' }
                        if (!$showURLs) { $excludeProperty += 'PolicyURL' }
                        $resultsWithoutSettings = $resultsWithoutSettings | Select-Object -Property * -exclude $excludeProperty
                        # sort
                        $resultsWithoutSettings = $resultsWithoutSettings | Sort-Object -Property Scope
                        #endregion prepare data

                        # render policies
                        New-HTMLSection -HeaderText 'Policy' -HeaderBackGroundColor Wedgewood -BackgroundColor White {
                            New-HTMLTable -DataTable $resultsWithoutSettings -WordBreak 'break-all' -DisableInfo -HideButtons -DisablePaging -FixedHeader -FixedFooter
                        }
                    }
                }

                if ($resultsWithSettings) {
                    New-HTMLSection -HeaderText "Policies with settings details" -HeaderTextAlignment left -CanCollapse -BackgroundColor DeepSkyBlue -HeaderBackGroundColor DeepSkyBlue -HeaderTextSize 10 -HeaderTextColor EgyptianBlue -Direction row {
                        $resultsWithSettings | % {
                            $policy = $_
                            $policySetting = $_.settingDetails

                            #region prepare data
                            # exclude some not significant or needed properties
                            # SettingName is useless in HTML report from my point of view
                            # settingDetails will be shown in separate table, omit here
                            if ($showEnrollmentIDs) {
                                $excludeProperty = 'SettingName', 'SettingDetails'
                            } else {
                                $excludeProperty = 'SettingName', 'SettingDetails', 'EnrollmentId'
                            }

                            $policy = $policy | Select-Object -Property * -ExcludeProperty $excludeProperty
                            #endregion prepare data

                            New-HTMLSection -HeaderText $policy.PolicyName -HeaderTextAlignment left -CanCollapse -BackgroundColor White -HeaderBackGroundColor White -HeaderTextSize 12 -HeaderTextColor EgyptianBlue {
                                # render main policy
                                New-HTMLSection -HeaderText 'Policy' -HeaderBackGroundColor Wedgewood -BackgroundColor White {
                                    New-HTMLTable -DataTable $policy -WordBreak 'break-all' -HideFooter -DisableInfo -HideButtons -DisablePaging -DisableSearch -DisableOrdering
                                }

                                # render policy settings details
                                if ($policySetting) {
                                    if (@($policySetting).count -eq 1) {
                                        $detailsHTMLTableParam = @{
                                            DisableSearch   = $true
                                            DisableOrdering = $true
                                        }
                                    } else {
                                        $detailsHTMLTableParam = @{}
                                    }
                                    New-HTMLSection -HeaderText 'Policy settings' -HeaderBackGroundColor PictonBlue -BackgroundColor White {
                                        New-HTMLTable @detailsHTMLTableParam -DataTable $policySetting -WordBreak 'break-all' -AllProperties -FixedHeader -HideFooter -DisableInfo -HideButtons -DisablePaging -WarningAction SilentlyContinue {
                                            New-HTMLTableCondition -Name 'WinningProvider' -ComparisonType string -Operator 'ne' -Value 'Intune' -BackgroundColor Red -Color White #-Row
                                            New-HTMLTableCondition -Name 'LastError' -ComparisonType number -Operator 'ne' -Value 0 -BackgroundColor Red -Color White # -Row
                                            New-HTMLTableCondition -Name 'Error' -ComparisonType number -Operator 'ne' -Value 0 -BackgroundColor Red -Color White # -Row
                                        }
                                    }
                                }
                            }

                            # hack for getting new line between sections
                            New-HTMLText -Text '.' -Color DeepSkyBlue
                        }
                    }
                }
            } # end of main HTML section
        }
    }
    #endregion convert results to HTML and output
}