include $(TOPDIR)/rules.mk

PKG_NAME:=hello-arch
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/hello-arch
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Tiny compiled program used to test arch-specific builds
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) -o $(PKG_BUILD_DIR)/hello-arch $(PKG_BUILD_DIR)/hello.c
endef

define Package/hello-arch/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/hello-arch $(1)/usr/bin/
endef

$(eval $(call BuildPackage,hello-arch))
