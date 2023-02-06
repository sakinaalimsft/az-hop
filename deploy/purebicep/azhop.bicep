targetScope = 'resourceGroup'

var azhopResourceGroupName = resourceGroup().name

@description('Azure region to use')
param location string

@description('Branch name to deploy from - Default main')
param branchName string = 'main'

@description('Autogenerate passwords and SSH key pair.')
param autogenerateSecrets bool = false

@description('SSH Public Key for the Virtual Machines.')
@secure()
param adminSshPublicKey string = ''

@description('SSH Private Key for the Virtual Machines.')
@secure()
param adminSshPrivateKey string = ''

@description('The Windows/Active Directory password.')
@secure()
param adminPassword string = ''

// todo: change to database admin password
@description('Password for the Slurm accounting admin user')
@secure()
param slurmAccountingAdminPassword string = ''

@description('Run software installation from the Deployer VM. Default to true')
param softwareInstallFromDeployer bool = true

@description('Identity of the deployer if not deploying from a deployer VM')
param loggedUserObjectId string = ''

@description('Input configuration file in json format')
param azhopConfig object

var resourcePostfix = '${uniqueString(subscription().subscriptionId, azhopResourceGroupName)}x'

// Local variables to help in the simplication as functions doesn't exists
var jumpboxSshPort = contains(azhopConfig.jumpbox, 'ssh_port') ? azhopConfig.jumpbox.ssh_port : 22
var deployLustre = contains(azhopConfig, 'lustre') ? true : false
var enableWinViz = contains(azhopConfig, 'enable_remote_winviz') ? azhopConfig.enable_remote_winviz : false
var highAvailabilityForAD = contains(azhopConfig.ad, 'high_availability') ? azhopConfig.ad.high_availability : false

var linuxBaseImage = contains(azhopConfig, 'linux_base_image') ? azhopConfig.linux_base_image : 'OpenLogic:CentOS:7_9-gen2:latest'
var linuxBasePlan = contains(azhopConfig, 'linux_base_plan') ? azhopConfig.linux_base_plan : ''
var windowsBaseImage = contains(azhopConfig, 'windows_base_image') ? azhopConfig.windows_base_image : 'MicrosoftWindowsServer:WindowsServer:2019-Datacenter-smalldisk:latest'
var lustreBaseImage = contains(azhopConfig, 'lustre_base_image') ? azhopConfig.lustre_base_image : 'azhpc:azurehpc-lustre:azurehpc-lustre-2_12:latest'
var lustreBasePlan = contains(azhopConfig, 'lustre_base_plan') ? azhopConfig.lustre_base_plan : 'azhpc:azurehpc-lustre:azurehpc-lustre-2_12'

// Convert the azhop configuration file to a pivot format used for the deployment
var config = {
  admin_user: azhopConfig.admin_user
  keyvault_readers: contains(azhopConfig, 'key_vault_readers') ? ( empty(azhopConfig.key_vault_readers) ? [] : [ azhopConfig.key_vault_readers ] ) : []

  public_ip: contains(azhopConfig.locked_down_network, 'public_ip') ? azhopConfig.locked_down_network.public_ip : true
  deploy_gateway: contains(azhopConfig.network.vnet.subnets,'gateway')
  deploy_bastion: contains(azhopConfig.network.vnet.subnets,'bastion')
  deploy_lustre: deployLustre

  lock_down_network: {
    enforce: contains(azhopConfig.locked_down_network, 'enforce') ? azhopConfig.locked_down_network.enforce : false
    grant_access_from: contains(azhopConfig.locked_down_network, 'grant_access_from') ? ( empty(azhopConfig.locked_down_network.grant_access_from) ? [] : [ azhopConfig.locked_down_network.grant_access_from ] ) : []
  }

  queue_manager: contains(azhopConfig, 'queue_manager') ? azhopConfig.queue_manager : 'openpbs'

  slurm: {
    admin_user: contains(azhopConfig, 'database') ? (contains(azhopConfig.database, 'user') ? azhopConfig.database.user : 'sqladmin') : 'sqladmin'
    accounting_enabled: contains(azhopConfig.slurm, 'accounting_enabled') ? azhopConfig.slurm.accounting_enabled : false
    enroot_enabled: contains(azhopConfig.slurm, 'enroot_enabled') ? azhopConfig.slurm.enroot_enabled : false
  }

  enable_remote_winviz : enableWinViz
  deploy_sig: false // TODO

  homedir: 'nfsfiles'
  homedir_mountpoint: azhopConfig.mounts.home.mountpoint

  anf: {
    dual_protocol: contains(azhopConfig.anf, 'dual_protocol') ? azhopConfig.anf.dual_protocol : false
    service_level: contains(azhopConfig.anf, 'homefs_service_level') ? azhopConfig.anf.homefs_service_level : 'Standard'
    size_gb: contains(azhopConfig.anf, 'homefs_size_tb') ? azhopConfig.anf.homefs_size_tb*1024 : 4096
  }

  vnet: {
    tags: contains(azhopConfig.network.vnet,'tags') ? azhopConfig.network.vnet.tags : {}
    name: azhopConfig.network.vnet.name
    cidr: azhopConfig.network.vnet.address_space
    subnets: union (
      {
      frontend: {
        name: azhopConfig.network.vnet.subnets.frontend.name
        cidr: azhopConfig.network.vnet.subnets.frontend.address_prefixes
        service_endpoints: [
          'Microsoft.Storage'
        ]
      }
      admin: {
        name: azhopConfig.network.vnet.subnets.admin.name
        cidr: azhopConfig.network.vnet.subnets.admin.address_prefixes
        service_endpoints: [
          'Microsoft.KeyVault'
          'Microsoft.Storage'
        ]
      }
      netapp: {
        apply_nsg: false
        name: azhopConfig.network.vnet.subnets.netapp.name
        cidr: azhopConfig.network.vnet.subnets.netapp.address_prefixes
        delegations: [
          'Microsoft.Netapp/volumes'
        ]
      }
      ad: {
        name: azhopConfig.network.vnet.subnets.ad.name
        cidr: azhopConfig.network.vnet.subnets.ad.address_prefixes
      }
      compute: {
        name: azhopConfig.network.vnet.subnets.compute.name
        cidr: azhopConfig.network.vnet.subnets.compute.address_prefixes
        service_endpoints: [
          'Microsoft.Storage'
        ]
      }
    },
    contains(azhopConfig.network.vnet.subnets,'bastion') ? {
      bastion: {
        apply_nsg: false
        name: 'AzureBastionSubnet'
        cidr: azhopConfig.network.vnet.subnets.bastion.address_prefixes
      }
    } : {},
    contains(azhopConfig.network.vnet.subnets,'outbounddns') ? {
      outbounddns: {
        name: azhopConfig.network.vnet.subnets.outbounddns.name
        cidr: azhopConfig.network.vnet.subnets.outbounddns.address_prefixes
        delegations: [
          'Microsoft.Network/dnsResolvers'
        ]
      }
    } : {},
    contains(azhopConfig.network.vnet.subnets,'gateway') ? {
      gateway: {
        apply_nsg: false
        name: 'GatewaySubnet'
        cidr: azhopConfig.network.vnet.subnets.gateway.address_prefixes
      }
    } : {}
    )
    peerings: contains(azhopConfig.network,'peering') ? azhopConfig.network.peering : {}
  }

  images: {
    lustre: {
      plan: lustreBasePlan
      ref: {
        publisher: split(lustreBaseImage,':')[0]
        offer: split(lustreBaseImage,':')[1]
        sku: split(lustreBaseImage,':')[2]
        version: split(lustreBaseImage,':')[3]
      }
    }
    ubuntu: {
      ref: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts-gen2'
        version: 'latest'
      }
    }
    linux_base: {
      plan: linuxBasePlan
      ref: contains(linuxBaseImage, '/') ? {
        id: linuxBaseImage
      } : {
        publisher: split(linuxBaseImage,':')[0]
        offer: split(linuxBaseImage,':')[1]
        sku: split(linuxBaseImage,':')[2]
        version: split(linuxBaseImage,':')[3]
      }
    }
    win_base: {
      ref: contains(windowsBaseImage, '/') ? {
        id: windowsBaseImage
      } : {
        publisher: split(windowsBaseImage,':')[0]
        offer: split(windowsBaseImage,':')[1]
        sku: split(windowsBaseImage,':')[2]
        version: split(windowsBaseImage,':')[3]
      }
    }
  }

  vms: union(
    {
      deployer: union(
        {
          subnet: 'frontend'
          sku: azhopConfig.jumpbox.vm_size
          osdisksku: 'Standard_LRS'
          image: 'ubuntu'
          pip: contains(azhopConfig.locked_down_network, 'public_ip') ? azhopConfig.locked_down_network.public_ip : true
          sshPort: jumpboxSshPort
          asgs: [ 'asg-ssh', 'asg-jumpbox', 'asg-deployer', 'asg-ad-client', 'asg-telegraf', 'asg-nfs-client' ]
        }, softwareInstallFromDeployer ? {
          deploy_script: replace(loadTextContent('install.sh'), '__INSERT_AZHOP_BRANCH__', branchName)
          identity: {
            keyvault: {
              key_permissions: [ 'All' ]
              secret_permissions: [ 'All' ]
            }
            roles: [
              'Contributor'
              'UserAccessAdministrator'
            ]
          }
        } : {
          deploy_script: jumpboxSshPort != 22 ? replace(loadTextContent('jumpbox.yml'), '__SSH_PORT__', string(jumpboxSshPort)) : ''
        }
      )
      ad: {
        subnet: 'ad'
        windows: true
        ahub: contains(azhopConfig.ad, 'hybrid_benefit') ? azhopConfig.ad.hybrid_benefit : false
        sku: azhopConfig.ad.vm_size
        osdisksku: 'StandardSSD_LRS'
        image: 'win_base'
        asgs: [ 'asg-ad', 'asg-rdp', 'asg-ad-client' ]
      }
      ondemand: {
        subnet: 'frontend'
        sku: azhopConfig.ondemand.vm_size
        osdisksku: 'StandardSSD_LRS'
        image: 'linux_base'
        pip: contains(azhopConfig.locked_down_network, 'public_ip') ? azhopConfig.locked_down_network.public_ip : true
        asgs: union(
          [ 'asg-ssh', 'asg-ondemand', 'asg-ad-client', 'asg-nfs-client', 'asg-pbs-client', 'asg-telegraf', 'asg-guacamole', 'asg-cyclecloud-client', 'asg-mariadb-client' ],
          deployLustre ? [ 'asg-lustre-client' ] : []
        )
      }
      grafana: {
        subnet: 'admin'
        sku: azhopConfig.grafana.vm_size
        osdisksku: 'StandardSSD_LRS'
        image: 'linux_base'
        asgs: [ 'asg-ssh', 'asg-grafana', 'asg-ad-client', 'asg-telegraf', 'asg-nfs-client' ]
      }
      ccportal: {
        subnet: 'admin'
        sku: azhopConfig.cyclecloud.vm_size
        osdisksku: 'StandardSSD_LRS'
        image: 'linux_base'
        datadisks: [
          {
            name: 'ccportal-datadisk0'
            disksku: 'Premium_LRS'
            size: 128
            caching: 'ReadWrite'
          }
        ]
        identity: {
          roles: [
            'Contributor'
          ]
        }
        asgs: [ 'asg-ssh', 'asg-cyclecloud', 'asg-telegraf', 'asg-ad-client' ]
      }
      scheduler: {
        subnet: 'admin'
        sku: azhopConfig.scheduler.vm_size
        osdisksku: 'StandardSSD_LRS'
        image: 'linux_base'
        asgs: [ 'asg-ssh', 'asg-pbs', 'asg-ad-client', 'asg-cyclecloud-client', 'asg-nfs-client', 'asg-telegraf', 'asg-mariadb-client' ]
      }
    },
    highAvailabilityForAD ? {
      ad2: {
        subnet: 'ad'
        windows: true
        ahub: contains(azhopConfig.ad, 'hybrid_benefit') ? azhopConfig.ad.hybrid_benefit : false
        sku: azhopConfig.ad.vm_size
        osdisksku: 'StandardSSD_LRS'
        image: 'win_base'
        asgs: [ 'asg-ad', 'asg-rdp', 'asg-ad-client' ]
      }
    } : {} ,
    enableWinViz ? {
      guacamole: {
      identity: {
        keyvault: {
          key_permissions: [ 'Get', 'List' ]
          secret_permissions: [ 'Get', 'List' ]
        }
      }
      subnet: 'admin'
      sku: azhopConfig.guacamole.vm_size
      osdisksku: 'StandardSSD_LRS'
      image: 'linux_base'
      asgs: [ 'asg-ssh', 'asg-ad-client', 'asg-telegraf', 'asg-nfs-client', 'asg-cyclecloud-client', 'asg-mariadb-client' ]
      }
    } : {},
    deployLustre ? {
      lustre: {
        subnet: 'admin'
        sku: azhopConfig.lustre.mds_sku
        osdisksku: 'StandardSSD_LRS'
        image: 'lustre'
        asgs: [ 'asg-ssh', 'asg-lustre', 'asg-lustre-client', 'asg-telegraf' ]
      }
      'lustre-oss': {
        count: azhopConfig.lustre.oss_count
        identity: {
          keyvault: {
            key_permissions: [ 'Get', 'List' ]
            secret_permissions: [ 'Get', 'List' ]
          }
        }
        subnet: 'admin'
        sku: azhopConfig.lustre.oss_sku
        osdisksku: 'StandardSSD_LRS'
        image: 'lustre'
        asgs: [ 'asg-ssh', 'asg-lustre', 'asg-lustre-client', 'asg-telegraf' ]
      }
      robinhood: {
        identity: {
          keyvault: {
            key_permissions: [ 'Get', 'List' ]
            secret_permissions: [ 'Get', 'List' ]
          }
        }
        subnet: 'admin'
        sku: azhopConfig.lustre.rbh_sku
        osdisksku: 'StandardSSD_LRS'
        image: 'lustre'
        asgs: [ 'asg-ssh', 'asg-robinhood', 'asg-lustre-client', 'asg-telegraf' ]
      }
    } : {}
  )

  asg_names: union([ 'asg-ssh', 'asg-rdp', 'asg-jumpbox', 'asg-ad', 'asg-ad-client', 'asg-pbs', 'asg-pbs-client', 'asg-cyclecloud', 'asg-cyclecloud-client', 'asg-nfs-client', 'asg-telegraf', 'asg-grafana', 'asg-robinhood', 'asg-ondemand', 'asg-deployer', 'asg-guacamole', 'asg-mariadb-client' ],
    deployLustre ? [ 'asg-lustre', 'asg-lustre-client' ] : []
  )

  service_ports: {
    All: ['0-65535']
    Bastion: ['22', '3389']
    Web: ['443', '80']
    Ssh: ['22']
    Public_Ssh: [string(jumpboxSshPort)]
    Socks: ['5985']
    // DNS, Kerberos, RpcMapper, Ldap, Smb, KerberosPass, LdapSsl, LdapGc, LdapGcSsl, AD Web Services, RpcSam
    DomainControlerTcp: ['53', '88', '135', '389', '445', '464', '636', '3268', '3269', '9389', '49152-65535']
    // DNS, Kerberos, W32Time, NetBIOS, Ldap, KerberosPass, LdapSsl
    DomainControlerUdp: ['53', '88', '123', '138', '389', '464', '636']
    // Web, NoVNC, WebSockify
    NoVnc: ['80', '443', '5900-5910', '61001-61010']
    Dns: ['53']
    Rdp: ['3389']
    Pbs: ['6200', '15001-15009', '17001', '32768-61000', '6817-6819']
    Slurmd: ['6818']
    Lustre: ['635', '988']
    Nfs: ['111', '635', '2049', '4045', '4046']
    SMB: ['445']
    Telegraf: ['8086']
    Grafana: ['3000']
    // HTTPS, AMQP
    CycleCloud: ['9443', '5672']
    MariaDB: ['3306', '33060']
    Guacamole: ['8080']
    WinRM: ['5985', '5986']
  }

  nsg_rules: {
      default: {
      //
      // INBOUND RULES
      //
    
      // AD communication
      AllowAdServerTcpIn          : ['220', 'Inbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad', 'asg', 'asg-ad-client']
      AllowAdServerUdpIn          : ['230', 'Inbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad', 'asg', 'asg-ad-client']
      AllowAdClientTcpIn          : ['240', 'Inbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad-client', 'asg', 'asg-ad']
      AllowAdClientUdpIn          : ['250', 'Inbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad-client', 'asg', 'asg-ad']
      AllowAdServerComputeTcpIn   : ['260', 'Inbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad', 'subnet', 'compute']
      AllowAdServerComputeUdpIn   : ['270', 'Inbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad', 'subnet', 'compute']
      AllowAdClientComputeTcpIn   : ['280', 'Inbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'subnet', 'compute', 'asg', 'asg-ad']
      AllowAdClientComputeUdpIn   : ['290', 'Inbound', 'Allow', 'Udp', 'DomainControlerUdp', 'subnet', 'compute', 'asg', 'asg-ad']
      AllowAdServerNetappTcpIn    : ['300', 'Inbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'subnet', 'netapp', 'asg', 'asg-ad']
      AllowAdServerNetappUdpIn    : ['310', 'Inbound', 'Allow', 'Udp', 'DomainControlerUdp', 'subnet', 'netapp', 'asg', 'asg-ad']
    
      // SSH internal rules
      AllowSshFromJumpboxIn       : ['320', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-jumpbox', 'asg', 'asg-ssh']
      AllowSshFromComputeIn       : ['330', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'subnet', 'compute', 'asg', 'asg-ssh']
      // Only in a deployer VM scenario
      AllowSshFromDeployerIn      : ['340', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-deployer', 'asg', 'asg-ssh'] 
      // Only in a deployer VM scenario
      AllowDeployerToPackerSshIn  : ['350', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-deployer', 'subnet', 'admin']
      AllowSshToComputeIn         : ['360', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-ssh', 'subnet', 'compute']
      AllowSshComputeComputeIn    : ['365', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'subnet', 'compute', 'subnet', 'compute']
    
      // PBS
      AllowPbsIn                  : ['369', 'Inbound', 'Allow', '*', 'Pbs', 'asg', 'asg-pbs', 'asg', 'asg-pbs-client']
      AllowPbsClientIn            : ['370', 'Inbound', 'Allow', '*', 'Pbs', 'asg', 'asg-pbs-client', 'asg', 'asg-pbs']
      AllowPbsComputeIn           : ['380', 'Inbound', 'Allow', '*', 'Pbs', 'asg', 'asg-pbs', 'subnet', 'compute']
      AllowComputePbsClientIn     : ['390', 'Inbound', 'Allow', '*', 'Pbs', 'subnet', 'compute', 'asg', 'asg-pbs-client']
      AllowComputePbsIn           : ['400', 'Inbound', 'Allow', '*', 'Pbs', 'subnet', 'compute', 'asg', 'asg-pbs']
      AllowComputeComputePbsIn    : ['401', 'Inbound', 'Allow', '*', 'Pbs', 'subnet', 'compute', 'subnet', 'compute']
    
      // SLURM
      AllowComputeSlurmIn         : ['405', 'Inbound', 'Allow', '*', 'Slurmd', 'asg', 'asg-ondemand', 'subnet', 'compute']
    
      // CycleCloud
      AllowCycleWebIn             : ['440', 'Inbound', 'Allow', 'Tcp', 'Web', 'asg', 'asg-ondemand', 'asg', 'asg-cyclecloud']
      AllowCycleClientIn          : ['450', 'Inbound', 'Allow', 'Tcp', 'CycleCloud', 'asg', 'asg-cyclecloud-client', 'asg', 'asg-cyclecloud']
      AllowCycleClientComputeIn   : ['460', 'Inbound', 'Allow', 'Tcp', 'CycleCloud', 'subnet', 'compute', 'asg', 'asg-cyclecloud']
      AllowCycleServerIn          : ['465', 'Inbound', 'Allow', 'Tcp', 'CycleCloud', 'asg', 'asg-cyclecloud', 'asg', 'asg-cyclecloud-client']
    
      // OnDemand NoVNC
      AllowComputeNoVncIn         : ['470', 'Inbound', 'Allow', 'Tcp', 'NoVnc', 'subnet', 'compute', 'asg', 'asg-ondemand']
      AllowNoVncComputeIn         : ['480', 'Inbound', 'Allow', 'Tcp', 'NoVnc', 'asg', 'asg-ondemand', 'subnet', 'compute']
    
      // Telegraf / Grafana
      AllowTelegrafIn             : ['490', 'Inbound', 'Allow', 'Tcp', 'Telegraf', 'asg', 'asg-telegraf', 'asg', 'asg-grafana']
      AllowComputeTelegrafIn      : ['500', 'Inbound', 'Allow', 'Tcp', 'Telegraf', 'subnet', 'compute', 'asg', 'asg-grafana']
      AllowGrafanaIn              : ['510', 'Inbound', 'Allow', 'Tcp', 'Grafana', 'asg', 'asg-ondemand', 'asg', 'asg-grafana']
    
      // Admin and Deployment
      AllowWinRMIn                : ['520', 'Inbound', 'Allow', 'Tcp', 'WinRM', 'asg', 'asg-jumpbox', 'asg', 'asg-rdp']
      AllowRdpIn                  : ['550', 'Inbound', 'Allow', 'Tcp', 'Rdp', 'asg', 'asg-jumpbox', 'asg', 'asg-rdp']
      AllowWebDeployerIn          : ['595', 'Inbound', 'Allow', 'Tcp', 'Web', 'asg', 'asg-deployer', 'asg', 'asg-ondemand']
    
      // Guacamole
      AllowGuacamoleRdpIn         : ['610', 'Inbound', 'Allow', 'Tcp', 'Rdp', 'asg', 'asg-guacamole', 'subnet', 'compute']
    
      // MariaDB
      AllowMariaDBIn              : ['700', 'Inbound', 'Allow', 'Tcp', 'MariaDB', 'asg', 'asg-mariadb-client', 'subnet', 'admin']

      // Deny all remaining traffic
      DenyVnetInbound             : ['3100', 'Inbound', 'Deny', '*', 'All', 'tag', 'VirtualNetwork', 'tag', 'VirtualNetwork']
    
    
      //
      // Outbound
      //
    
      // AD communication
      AllowAdClientTcpOut         : ['200', 'Outbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad-client', 'asg', 'asg-ad']
      AllowAdClientUdpOut         : ['210', 'Outbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad-client', 'asg', 'asg-ad']
      AllowAdClientComputeTcpOut  : ['220', 'Outbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'subnet', 'compute', 'asg', 'asg-ad']
      AllowAdClientComputeUdpOut  : ['230', 'Outbound', 'Allow', 'Udp', 'DomainControlerUdp', 'subnet', 'compute', 'asg', 'asg-ad']
      AllowAdServerTcpOut         : ['240', 'Outbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad', 'asg', 'asg-ad-client']
      AllowAdServerUdpOut         : ['250', 'Outbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad', 'asg', 'asg-ad-client']
      AllowAdServerComputeTcpOut  : ['260', 'Outbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad', 'subnet', 'compute']
      AllowAdServerComputeUdpOut  : ['270', 'Outbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad', 'subnet', 'compute']
      AllowAdServerNetappTcpOut   : ['280', 'Outbound', 'Allow', 'Tcp', 'DomainControlerTcp', 'asg', 'asg-ad', 'subnet', 'netapp']
      AllowAdServerNetappUdpOut   : ['290', 'Outbound', 'Allow', 'Udp', 'DomainControlerUdp', 'asg', 'asg-ad', 'subnet', 'netapp']
    
      // CycleCloud
      AllowCycleServerOut         : ['300', 'Outbound', 'Allow', 'Tcp', 'CycleCloud', 'asg', 'asg-cyclecloud', 'asg', 'asg-cyclecloud-client']
      AllowCycleClientOut         : ['310', 'Outbound', 'Allow', 'Tcp', 'CycleCloud', 'asg', 'asg-cyclecloud-client', 'asg', 'asg-cyclecloud']
      AllowComputeCycleClientIn   : ['320', 'Outbound', 'Allow', 'Tcp', 'CycleCloud', 'subnet', 'compute', 'asg', 'asg-cyclecloud']
      AllowCycleWebOut            : ['330', 'Outbound', 'Allow', 'Tcp', 'Web', 'asg', 'asg-ondemand', 'asg', 'asg-cyclecloud']
    
      // PBS
      AllowPbsOut                 : ['340', 'Outbound', 'Allow', '*', 'Pbs', 'asg', 'asg-pbs', 'asg', 'asg-pbs-client']
      AllowPbsClientOut           : ['350', 'Outbound', 'Allow', '*', 'Pbs', 'asg', 'asg-pbs-client', 'asg', 'asg-pbs']
      AllowPbsComputeOut          : ['360', 'Outbound', 'Allow', '*', 'Pbs', 'asg', 'asg-pbs', 'subnet', 'compute']
      AllowPbsClientComputeOut    : ['370', 'Outbound', 'Allow', '*', 'Pbs', 'subnet', 'compute', 'asg', 'asg-pbs']
      AllowComputePbsClientOut    : ['380', 'Outbound', 'Allow', '*', 'Pbs', 'subnet', 'compute', 'asg', 'asg-pbs-client']
      AllowComputeComputePbsOut   : ['381', 'Outbound', 'Allow', '*', 'Pbs', 'subnet', 'compute', 'subnet', 'compute']
    
      // SLURM
      AllowSlurmComputeOut        : ['385', 'Outbound', 'Allow', '*', 'Slurmd', 'asg', 'asg-ondemand', 'subnet', 'compute']
    
      // NFS
      AllowNfsOut                 : ['440', 'Outbound', 'Allow', '*', 'Nfs', 'asg', 'asg-nfs-client', 'subnet', 'netapp']
      AllowNfsComputeOut          : ['450', 'Outbound', 'Allow', '*', 'Nfs', 'subnet', 'compute', 'subnet', 'netapp']
    
      // Telegraf / Grafana
      AllowTelegrafOut            : ['460', 'Outbound', 'Allow', 'Tcp', 'Telegraf', 'asg', 'asg-telegraf', 'asg', 'asg-grafana']
      AllowComputeTelegrafOut     : ['470', 'Outbound', 'Allow', 'Tcp', 'Telegraf', 'subnet', 'compute', 'asg', 'asg-grafana']
      AllowGrafanaOut             : ['480', 'Outbound', 'Allow', 'Tcp', 'Grafana', 'asg', 'asg-ondemand', 'asg', 'asg-grafana']
    
      // SSH internal rules
      AllowSshFromJumpboxOut      : ['490', 'Outbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-jumpbox', 'asg', 'asg-ssh']
      AllowSshComputeOut          : ['500', 'Outbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-ssh', 'subnet', 'compute']
      AllowSshDeployerOut         : ['510', 'Outbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-deployer', 'asg', 'asg-ssh']
      AllowSshDeployerPackerOut   : ['520', 'Outbound', 'Allow', 'Tcp', 'Ssh', 'asg', 'asg-deployer', 'subnet', 'admin']
      AllowSshFromComputeOut      : ['530', 'Outbound', 'Allow', 'Tcp', 'Ssh', 'subnet', 'compute', 'asg', 'asg-ssh']
      AllowSshComputeComputeOut   : ['540', 'Outbound', 'Allow', 'Tcp', 'Ssh', 'subnet', 'compute', 'subnet', 'compute']
    
      // OnDemand NoVNC
      AllowComputeNoVncOut        : ['550', 'Outbound', 'Allow', 'Tcp', 'NoVnc', 'subnet', 'compute', 'asg', 'asg-ondemand']
      AllowNoVncComputeOut        : ['560', 'Outbound', 'Allow', 'Tcp', 'NoVnc', 'asg', 'asg-ondemand', 'subnet', 'compute']
    
      // Admin and Deployment
      AllowRdpOut                 : ['570', 'Outbound', 'Allow', 'Tcp', 'Rdp', 'asg', 'asg-jumpbox', 'asg', 'asg-rdp']
      AllowWinRMOut               : ['580', 'Outbound', 'Allow', 'Tcp', 'WinRM', 'asg', 'asg-jumpbox', 'asg', 'asg-rdp']
      AllowDnsOut                 : ['590', 'Outbound', 'Allow', '*', 'Dns', 'tag', 'VirtualNetwork', 'tag', 'VirtualNetwork']
      AllowWebDeployerOut         : ['595', 'Outbound', 'Allow', 'Tcp', 'Web', 'asg', 'asg-deployer', 'asg', 'asg-ondemand']
    
      // Guacamole
      AllowGuacamoleRdpOut        : ['610', 'Outbound', 'Allow', 'Tcp', 'Rdp', 'asg', 'asg-guacamole', 'subnet', 'compute']
      
      // MariaDB
      AllowMariaDBOut             : ['700', 'Outbound', 'Allow', 'Tcp', 'MariaDB', 'asg', 'asg-mariadb-client', 'subnet', 'admin']
      
      // Deny all remaining traffic and allow Internet access
      AllowInternetOutBound       : ['3000', 'Outbound', 'Allow', 'Tcp', 'All', 'tag', 'VirtualNetwork', 'tag', 'Internet']
      DenyVnetOutbound            : ['3100', 'Outbound', 'Deny', '*', 'All', 'tag', 'VirtualNetwork', 'tag', 'VirtualNetwork']
    }
    lustre: {
      // Inbound
      AllowLustreIn               : ['409', 'Inbound', 'Allow', 'Tcp', 'Lustre', 'asg', 'asg-lustre', 'asg', 'asg-lustre-client']
      AllowLustreClientIn         : ['410', 'Inbound', 'Allow', 'Tcp', 'Lustre', 'asg', 'asg-lustre-client', 'asg', 'asg-lustre']
      AllowLustreClientComputeIn  : ['420', 'Inbound', 'Allow', 'Tcp', 'Lustre', 'subnet', 'compute', 'asg', 'asg-lustre']
      AllowRobinhoodIn            : ['430', 'Inbound', 'Allow', 'Tcp', 'Web', 'asg', 'asg-ondemand', 'asg', 'asg-robinhood']
      // Outbound
      AllowLustreOut              : ['390', 'Outbound', 'Allow', 'Tcp', 'Lustre', 'asg', 'asg-lustre', 'asg', 'asg-lustre-client']
      AllowLustreClientOut        : ['400', 'Outbound', 'Allow', 'Tcp', 'Lustre', 'asg', 'asg-lustre-client', 'asg', 'asg-lustre']
      //AllowLustreComputeOut       : ['410', 'Outbound', 'Allow', 'Tcp', 'Lustre', 'asg', 'asg-lustre', 'subnet', 'compute']
      AllowLustreClientComputeOut : ['420', 'Outbound', 'Allow', 'Tcp', 'Lustre', 'subnet', 'compute', 'asg', 'asg-lustre']
      AllowRobinhoodOut           : ['430', 'Outbound', 'Allow', 'Tcp', 'Web', 'asg', 'asg-ondemand', 'asg', 'asg-robinhood']
    }
    internet: {
      AllowInternetSshIn          : ['200', 'Inbound', 'Allow', 'Tcp', 'Ssh', 'tag', 'Internet', 'asg', 'asg-jumpbox']
      AllowInternetHttpIn         : ['210', 'Inbound', 'Allow', 'Tcp', 'Web', 'tag', 'Internet', 'asg', 'asg-ondemand']
    }
    hub: {
      AllowHubSshIn               : ['200', 'Inbound', 'Allow', 'Tcp', 'Public_Ssh', 'tag', 'VirtualNetwork', 'asg', 'asg-jumpbox']
      AllowHubHttpIn              : ['210', 'Inbound', 'Allow', 'Tcp', 'Web',        'tag', 'VirtualNetwork', 'asg', 'asg-ondemand']
    }
    bastion: {
      AllowBastionIn              : ['530', 'Inbound', 'Allow', 'Tcp', 'Bastion', 'subnet', 'bastion', 'tag', 'VirtualNetwork']
    }
    gateway: {
      AllowInternalWebUsersIn     : ['540', 'Inbound', 'Allow', 'Tcp', 'Web', 'subnet', 'gateway', 'asg', 'asg-ondemand']
    }
  }

}

module azhopSecrets './secrets.bicep' = if (autogenerateSecrets) {
  name: 'azhopSecrets'
  params: {
    location: location
  }
}

var secrets = (autogenerateSecrets) ? azhopSecrets.outputs.secrets : {
  adminSshPublicKey: adminSshPublicKey
  adminSshPrivateKey: adminSshPrivateKey
  adminPassword: adminPassword
  slurmAccountingAdminPassword: slurmAccountingAdminPassword
}

module azhopNetwork './network.bicep' = {
  name: 'azhopNetwork'
  params: {
    location: location
    deployGateway: config.deploy_gateway
    deployBastion: config.deploy_bastion
    deployLustre: config.deploy_lustre
    publicIp: config.public_ip
    vnet: config.vnet
    asgNames: config.asg_names
    servicePorts: config.service_ports
    nsgRules: config.nsg_rules
    peerings: config.vnet.peerings
  }
}

output vnetId string = azhopNetwork.outputs.vnetId

var subnetIds = azhopNetwork.outputs.subnetIds
var asgNameToIdLookup = reduce(azhopNetwork.outputs.asgIds, {}, (cur, next) => union(cur, next))


module azhopBastion './bastion.bicep' = if (config.deploy_bastion) {
  name: 'azhopBastion'
  params: {
    location: location
    subnetId: subnetIds.bastion
  }
}

var vmItems = items(config.vms)

module azhopVm './vm.bicep' = [ for vm in vmItems: {
  name: 'azhopVm${vm.key}'
  params: {
    location: location
    name: vm.key
    vm: vm.value
    image: config.images[vm.value.image]
    subnetId: subnetIds[vm.value.subnet]
    adminUser: config.admin_user
    secrets: secrets
    asgIds: asgNameToIdLookup
  }
}]

var keyvaultSecrets = union(
  [
    {
      name: '${config.admin_user}-password'
      value: secrets.adminPassword
    }
    {
      name: '${config.admin_user}-pubkey'
      value: secrets.adminSshPublicKey
    }
    {
      name: '${config.admin_user}-privkey'
      value: secrets.adminSshPrivateKey
    }
  ],
  (config.queue_manager == 'slurm' && config.slurm.accounting_enabled) ? [
    {
      name: '${config.slurm.admin_user}-password'
      value: secrets.slurmAccountingAdminPassword
    }
  ] : []
)

module azhopKeyvault './keyvault.bicep' = {
  name: 'azhopKeyvault'
  params: {
    location: location
    resourcePostfix: resourcePostfix
    subnetId: subnetIds.admin
    keyvaultReaderOids: config.keyvault_readers
    lockDownNetwork: config.lock_down_network.enforce
    allowableIps: config.lock_down_network.grant_access_from
    keyvaultOwnerId: loggedUserObjectId
    identityPerms: [ for i in range(0, length(vmItems)): {
      principalId: azhopVm[i].outputs.principalId
      key_permissions: (contains(vmItems[i].value, 'identity') && contains(vmItems[i].value.identity, 'keyvault')) ? vmItems[i].value.identity.keyvault.key_permissions : []
      secret_permissions: (contains(vmItems[i].value, 'identity') && contains(vmItems[i].value.identity, 'keyvault')) ? vmItems[i].value.identity.keyvault.secret_permissions : []
    }]
    secrets: keyvaultSecrets
  }
}

module azhopStorage './storage.bicep' = {
  name: 'azhopStorage'
  params:{
    location: location
    resourcePostfix: resourcePostfix
    lockDownNetwork: config.lock_down_network.enforce
    allowableIps: config.lock_down_network.grant_access_from
    subnetIds: [ subnetIds.admin, subnetIds.compute ]
  }
}

module azhopSig './sig.bicep' = if (config.deploy_sig) {
  name: 'azhopSig'
  params: {
    location: location
    resourcePostfix: resourcePostfix
  }
}

var createDatabase = (config.queue_manager == 'slurm' && config.slurm.accounting_enabled ) || config.enable_remote_winviz
module azhopMariaDB './mariadb.bicep' = if (createDatabase) {
  name: 'azhopMariaDB'
  params: {
    location: location
    resourcePostfix: resourcePostfix
    adminUser: config.slurm.admin_user
    adminPassword: secrets.slurmAccountingAdminPassword
    adminSubnetId: subnetIds.admin
    vnetId: azhopNetwork.outputs.vnetId
    sslEnforcement: config.enable_remote_winviz ? false : true // based whether guacamole is enabled (guac doesn't support ssl atm)
  }
}

module azhopTelemetry './telemetry.bicep' = {
  name: 'azhopTelemetry'
}

module azhopVpnGateway './vpngateway.bicep' = if (config.deploy_gateway) {
  name: 'azhopVpnGateway'
  params: {
    location: location
    subnetId: subnetIds.gateway
  }
}

module azhopAnf './anf.bicep' = if (config.homedir == 'anf') {
  name: 'azhopAnf'
  params: {
    location: location
    resourcePostfix: resourcePostfix
    dualProtocol: config.anf.dual_protocol
    subnetId: subnetIds.netapp
    adUser: config.admin_user
    adPassword: secrets.adminPassword
    adDns: azhopVm[indexOf(map(vmItems, item => item.key), 'ad')].outputs.privateIps[0]
    serviceLevel: config.anf.service_level
    sizeGB: config.anf.size_gb
  }
}

module azhopNfsFiles './nfsfiles.bicep' = if (config.homedir == 'nfsfiles') {
  name: 'azhopNfsFiles'
  params: {
    location: location
    resourcePostfix: resourcePostfix
    allowedSubnetIds: [ subnetIds.admin, subnetIds.compute, subnetIds.frontend ]
    sizeGB: 1024
  }
}

module azhopPrivateZone './privatezone.bicep' = {
  name: 'azhopPrivateZone'
  params: {
    privateDnsZoneName: 'hpc.azure'
    vnetId: azhopNetwork.outputs.vnetId
  }
}

// list of DC VMs. The first one will be considered the default PDC (for DNS registration)
var adVmNames = (indexOf(map(vmItems, item => item.key), 'ad2') > 0 ? ['ad', 'ad2'] : ['ad'])
var adVmIps = (indexOf(map(vmItems, item => item.key), 'ad2') > 0 ? [azhopVm[indexOf(map(vmItems, item => item.key), 'ad')].outputs.privateIps[0], azhopVm[indexOf(map(vmItems, item => item.key), 'ad2')].outputs.privateIps[0]] : azhopVm[indexOf(map(vmItems, item => item.key), 'ad')].outputs.privateIps[0])
module azhopADRecords './privatezone_records.bicep' = {
  name: 'azhopADRecords'
  params: {
    privateDnsZoneName: 'hpc.azure'
    adVmNames: adVmNames
    adVmIps: adVmIps
  }
}

output ccportalPrincipalId string = azhopVm[indexOf(map(vmItems, item => item.key), 'ccportal')].outputs.principalId

output keyvaultName string = azhopKeyvault.outputs.keyvaultName

// Our input file is also the deployment output
output azhopConfig object = azhopConfig

var envNameToCloudMap = {
  AzureCloud: 'AZUREPUBLICCLOUD'
  AzureUSGovernment: 'AZUREUSGOVERNMENT'
  AzureGermanCloud: 'AZUREGERMANCLOUD'
  AzureChinaCloud: 'AZURECHINACLOUD'
}

var kvSuffix = environment().suffixes.keyvaultDns

output azhopGlobalConfig object = union(
  {
    global_ssh_public_key         : secrets.adminSshPublicKey
    global_cc_storage             : 'azhop${resourcePostfix}'
    compute_subnetid              : '${azhopResourceGroupName}/${config.vnet.name}/${config.vnet.subnets.compute.name}'
    global_config_file            : '/az-hop/config.yml'
    ad_join_user                  : config.admin_user
    domain_name                   : 'hpc.azure'
    ldap_server                   : 'ad'
    homedir_mountpoint            : config.homedir_mountpoint
    ondemand_fqdn                 : config.public_ip ? azhopVm[indexOf(map(vmItems, item => item.key), 'ondemand')].outputs.fqdn : azhopVm[indexOf(map(vmItems, item => item.key), 'ondemand')].outputs.privateIps[0]
    ansible_ssh_private_key_file  : '${config.admin_user}_id_rsa'
    subscription_id               : subscription().subscriptionId
    tenant_id                     : subscription().tenantId
    key_vault                     : 'kv${resourcePostfix}'
    sig_name                      : (config.deploy_sig) ? 'azhop_${resourcePostfix}' : ''
    lustre_hsm_storage_account    : 'azhop${resourcePostfix}'
    lustre_hsm_storage_container  : 'lustre'
    database_fqdn                 : (config.queue_manager == 'slurm' && config.slurm.accounting_enabled) ? azhopMariaDB.outputs.mariaDb_fqdn : ''
    database_user                 : config.slurm.admin_user
    azure_environment             : envNameToCloudMap[environment().name]
    key_vault_suffix              : substring(kvSuffix, 1, length(kvSuffix) - 1) // vault.azure.net - remove leading dot from env
    blob_storage_suffix           : 'blob.${environment().suffixes.storage}' // blob.core.windows.net
    jumpbox_ssh_port              : config.vms.deployer.sshPort
  },
  config.homedir == 'anf' ? {
    anf_home_ip                   : azhopAnf.outputs.nfs_home_ip
    anf_home_path                 : azhopAnf.outputs.nfs_home_path
    anf_home_opts                 : azhopAnf.outputs.nfs_home_opts
  } : {},
  config.homedir == 'nfsfiles' ? {
    anf_home_ip                   : azhopNfsFiles.outputs.nfs_home_ip
    anf_home_path                 : azhopNfsFiles.outputs.nfs_home_path
    anf_home_opts                 : azhopNfsFiles.outputs.nfs_home_opts
  } : {}
)

output azhopInventory object = {
  all: {
    hosts: union (
      {
        localhost: {
          psrp_ssh_proxy: softwareInstallFromDeployer ? '' : azhopVm[indexOf(map(vmItems, item => item.key), 'deployer')].outputs.privateIps[0]
        }
        scheduler: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'scheduler')].outputs.privateIps[0]
        }
        ondemand: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'ondemand')].outputs.privateIps[0]
        }
        ccportal: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'ccportal')].outputs.privateIps[0]
        }
        grafana: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'grafana')].outputs.privateIps[0]
        }
        ad: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'ad')].outputs.privateIps[0]
          ansible_connection: 'psrp'
          ansible_psrp_protocol: 'http'
          ansible_user: config.admin_user
          ansible_password: secrets.adminPassword
          psrp_ssh_proxy: softwareInstallFromDeployer ? '' : azhopVm[indexOf(map(vmItems, item => item.key), 'deployer')].outputs.privateIps[0]
          ansible_psrp_proxy: softwareInstallFromDeployer ? '' : 'socks5h://localhost:5985'
        }
      },
      indexOf(map(vmItems, item => item.key), 'ad2') > 0 ? {
        ad2: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'ad2')].outputs.privateIps[0]
          ansible_connection: 'psrp'
          ansible_psrp_protocol: 'http'
          ansible_user: config.admin_user
          ansible_password: secrets.adminPassword
          psrp_ssh_proxy: softwareInstallFromDeployer ? '' : azhopVm[indexOf(map(vmItems, item => item.key), 'deployer')].outputs.privateIps[0]
          ansible_psrp_proxy: softwareInstallFromDeployer ? '' : 'socks5h://localhost:5985'
        }
      } : {} ,
      softwareInstallFromDeployer ? {} : {
        jumpbox : {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'deployer')].outputs.privateIps[0]
          ansible_ssh_port: config.vms.deployer.sshPort
          ansible_ssh_common_args: ''
        }
      },
      config.deploy_lustre ? {
        lustre: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'lustre')].outputs.privateIps[0]
        }
        robinhood: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'robinhood')].outputs.privateIps[0]
        }
      } : {},
      config.enable_remote_winviz ? {
        guacamole: {
          ansible_host: azhopVm[indexOf(map(vmItems, item => item.key), 'guacamole')].outputs.privateIps[0]
        }
      } : {}
    )
    vars: {
      ansible_ssh_user: config.admin_user
      ansible_ssh_common_args: softwareInstallFromDeployer ? '' : '-o ProxyCommand="ssh -i ${config.admin_user}_id_rsa -p ${config.vms.deployer.sshPort} -W %h:%p ${config.admin_user}@${azhopVm[indexOf(map(vmItems, item => item.key), 'deployer')].outputs.privateIps[0]}"'
    }
  }
}

// need to add this to the inventory file as bicep will not allow me to generate it
output lustre_oss_private_ips array = config.deploy_lustre ? azhopVm[indexOf(map(vmItems, item => item.key), 'lustre-oss')].outputs.privateIps : []

output azhopPackerOptions object = (config.deploy_sig) ? {
  var_subscription_id: subscription().subscriptionId
  var_resource_group: azhopResourceGroupName
  var_location: location
  var_sig_name: 'azhop_${resourcePostfix}'
  var_private_virtual_network_with_public_ip: 'false'
  var_virtual_network_name: config.vnet.name
  var_virtual_network_subnet_name: config.vnet.subnets.compute.name
  var_virtual_network_resource_group_name: azhopResourceGroupName
  var_queue_manager: config.queue_manager
} : {}

var azhopConnectScript = format('''
#!/bin/bash

exec ssh -i {0}_id_rsa  "$@"

''', config.admin_user)

var azhopSSHConnectScript = format('''
#!/bin/bash

if [[ $1 == "cyclecloud" ]]; then
  echo go create tunnel to cyclecloud at https://localhost:9443/cyclecloud
  ssh -i {0}_id_rsa -fN -L 9443:ccportal:9443 -p {1} {0}@{2}
elif [[ $1 == "ad" ]]; then
  echo go create tunnel to ad with rdp to localhost:3390
  ssh -i {0}_id_rsa -fN -L 3390:ad:3389 -p {1} {0}@{2}
else
  exec ssh -i {0}_id_rsa -o ProxyCommand="ssh -i {0}_id_rsa -p {1} -W %h:%p {0}@{2}" "$@"
fi
''', config.admin_user, config.vms.deployer.sshPort, azhopVm[indexOf(map(vmItems, item => item.key), 'deployer')].outputs.privateIps[0])

output azhopConnectScript string = softwareInstallFromDeployer ? azhopConnectScript : azhopSSHConnectScript


output azhopGetSecretScript string = format('''
#!/bin/bash

user=$1
# Because secret names are restricted to '^[0-9a-zA-Z-]+$' we need to remove all other characters
secret_name=$(echo $user-password | tr -dc 'a-zA-Z0-9-')

az keyvault secret show --vault-name kv{0} -n $secret_name --query "value" -o tsv

''', resourcePostfix)

