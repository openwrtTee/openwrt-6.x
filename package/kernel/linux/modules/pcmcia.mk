#
# Copyright (C) 2006-2010 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

PCMCIA_MENU:=PCMCIA support

define KernelPackage/pcmcia-core
  SUBMENU:=$(PCMCIA_MENU)
  TITLE:=PCMCIA/CardBus support
  DEPENDS:=@PCMCIA_SUPPORT
  KCONFIG:= \
	CONFIG_PCMCIA \
	CONFIG_CARDBUS \
	CONFIG_PCCARD \
	PCMCIA_DEBUG=n
  FILES:= \
	$(LINUX_DIR)/drivers/pcmcia/pcmcia_core.ko \
	$(LINUX_DIR)/drivers/pcmcia/pcmcia.ko
  AUTOLOAD:=$(call AutoLoad,25,pcmcia_core pcmcia)
endef

define KernelPackage/pcmcia-core/description
 Kernel support for PCMCIA/CardBus controllers
endef

$(eval $(call KernelPackage,pcmcia-core))


define AddDepends/pcmcia
  SUBMENU:=$(PCMCIA_MENU)
  DEPENDS+=kmod-pcmcia-core $(1)
endef


define KernelPackage/pcmcia-rsrc
  TITLE:=PCMCIA resource support
  KCONFIG:=CONFIG_PCCARD_NONSTATIC=y
  FILES:=$(LINUX_DIR)/drivers/pcmcia/pcmcia_rsrc.ko
  AUTOLOAD:=$(call AutoLoad,26,pcmcia_rsrc)
  $(call AddDepends/pcmcia)
endef

define KernelPackage/pcmcia-rsrc/description
 Kernel support for PCMCIA resource allocation
endef

$(eval $(call KernelPackage,pcmcia-rsrc))


define KernelPackage/pcmcia-yenta
  TITLE:=yenta socket driver
  KCONFIG:=CONFIG_YENTA
  FILES:=$(LINUX_DIR)/drivers/pcmcia/yenta_socket.ko
  AUTOLOAD:=$(call AutoLoad,41,yenta_socket)
  DEPENDS:=+kmod-pcmcia-rsrc
  $(call AddDepends/pcmcia)
endef

$(eval $(call KernelPackage,pcmcia-yenta))


define KernelPackage/pcmcia-serial
  TITLE:=Serial devices support
  KCONFIG:= \
	CONFIG_PCMCIA_SERIAL_CS \
	CONFIG_SERIAL_8250_CS
  FILES:=$(LINUX_DIR)/drivers/tty/serial/8250/serial_cs.ko
  AUTOLOAD:=$(call AutoLoad,45,serial_cs)
  DEPENDS:=+kmod-serial-8250
  $(call AddDepends/pcmcia)
endef

define KernelPackage/pcmcia-serial/description
 Kernel support for PCMCIA/CardBus serial devices
endef

$(eval $(call KernelPackage,pcmcia-serial))
