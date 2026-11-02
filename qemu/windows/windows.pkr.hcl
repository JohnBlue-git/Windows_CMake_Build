// Packer template: unattended Windows Server 2022 (Server Core) install into a
// QEMU qcow2 disk, then installs VS 2022 C++ Build Tools + CMake + OpenSSH.
// Works with the stock Microsoft ISO or with the custom ISO from iso-kit/
// (which already installs the toolchain during Setup; the provisioner then
// only verifies it).
//
// Normally run through ./build-image.sh, which checks prerequisites and fills
// in the variables below.

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "Path or URL of the Windows Server 2022 ISO (evaluation or licensed)."
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "e.g. sha256:<hash>. 'none' skips verification."
}

variable "image_name" {
  type        = string
  default     = "Windows Server 2022 SERVERSTANDARDCORE"
  description = "Image name inside sources/install.wim (list with: wiminfo install.wim)."
}

variable "image_index" {
  type        = number
  default     = 0
  description = "If > 0, select the image by index instead of image_name (custom ISOs from iso-kit contain one image: 1)."
}

variable "product_key" {
  type        = string
  default     = ""
  description = "Leave empty for evaluation media."
}

variable "admin_password" {
  type      = string
  default   = "CMakeDll!2026"
  sensitive = true
}

variable "ssh_public_key_file" {
  type        = string
  description = "Public key installed for Administrator so the host can ssh/scp into the VM."
}

variable "output_dir" {
  type    = string
  default = "output"
}

variable "vm_name" {
  type    = string
  default = "cmake-dll-win.qcow2"
}

variable "disk_size" {
  type    = string
  default = "60G"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 8192
}

variable "headless" {
  type    = bool
  default = true
}

source "qemu" "windows" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  output_directory = var.output_dir
  vm_name          = var.vm_name
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_compression = true

  accelerator  = "kvm"
  machine_type = "pc"
  cpus         = var.cpus
  memory       = var.memory

  // IDE disk + e1000 NIC: Windows has in-box drivers for both, so no
  // virtio-win driver ISO is needed. vm.sh must use the same devices.
  disk_interface = "ide"
  net_device     = "e1000"

  headless          = var.headless
  vnc_bind_address  = "127.0.0.1"
  vnc_port_min      = 5900
  vnc_port_max      = 5910

  // Windows Setup scans A:\ for autounattend.xml.
  floppy_content = {
    "autounattend.xml" = templatefile("${path.root}/autounattend.pkrtpl.xml", {
      admin_password = var.admin_password
      image_name     = var.image_name
      image_index    = var.image_index
      product_key    = var.product_key
    })
  }
  floppy_files = ["${path.root}/scripts/setup-winrm.ps1"]

  boot_wait    = "2s"
  boot_command = ["<spacebar><wait><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.admin_password
  winrm_timeout  = "4h"
  winrm_use_ssl  = false

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "30m"
}

build {
  sources = ["source.qemu.windows"]

  provisioner "file" {
    source      = var.ssh_public_key_file
    destination = "C:/Windows/Temp/host_key.pub"
  }

  provisioner "powershell" {
    scripts = ["${path.root}/scripts/install-openssh.ps1"]
  }

  provisioner "powershell" {
    scripts = ["${path.root}/scripts/install-buildtools.ps1"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    scripts = ["${path.root}/scripts/verify-toolchain.ps1"]
  }
}
