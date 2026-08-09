#include <linux/module.h>
#define INCLUDE_VERMAGIC
#include <linux/build-salt.h>
#include <linux/elfnote-lto.h>
#include <linux/export-internal.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

#ifdef CONFIG_UNWINDER_ORC
#include <asm/orc_header.h>
ORC_HEADER;
#endif

BUILD_SALT;
BUILD_LTO_INFO;

MODULE_INFO(vermagic, VERMAGIC_STRING);
MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

#ifdef CONFIG_MITIGATION_RETPOLINE
MODULE_INFO(retpoline, "Y");
#endif



static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0xbfe2c251, "dma_mmap_attrs" },
	{ 0x3cfc3eba, "platform_driver_unregister" },
	{ 0x51e15319, "devm_kmalloc" },
	{ 0xa49317d2, "dma_set_mask" },
	{ 0x49458713, "dev_err_probe" },
	{ 0x713213b1, "dma_set_coherent_mask" },
	{ 0x82a02e49, "platform_get_resource" },
	{ 0xb8febde6, "devm_ioremap_resource" },
	{ 0xc1869dc, "devm_ioremap" },
	{ 0x6b18d4d2, "dma_alloc_attrs" },
	{ 0xcefb0c9f, "__mutex_init" },
	{ 0x608741b5, "__init_swait_queue_head" },
	{ 0x1206e8a5, "misc_register" },
	{ 0x4dfa8d4b, "mutex_lock" },
	{ 0xc3055d20, "usleep_range_state" },
	{ 0x13c49cc2, "_copy_from_user" },
	{ 0x7f02188f, "__msecs_to_jiffies" },
	{ 0xf02aa937, "wait_for_completion_interruptible_timeout" },
	{ 0x3213f038, "mutex_unlock" },
	{ 0x6b10bee1, "_copy_to_user" },
	{ 0x2d3385d3, "system_wq" },
	{ 0xc5b6f236, "queue_work_on" },
	{ 0xf9a482f9, "msleep" },
	{ 0xf0fdf6cb, "__stack_chk_fail" },
	{ 0x54b1fac6, "__ubsan_handle_load_invalid_value" },
	{ 0x7f24de73, "jiffies_to_usecs" },
	{ 0x15ba50a6, "jiffies" },
	{ 0x93d6dd8c, "complete_all" },
	{ 0x122c3a7e, "_printk" },
	{ 0xbdfb6dbb, "__fentry__" },
	{ 0x5b8239ca, "__x86_return_thunk" },
	{ 0x8f7114d6, "__platform_driver_register" },
	{ 0x3c12dfe, "cancel_work_sync" },
	{ 0x31034322, "misc_deregister" },
	{ 0x7271639f, "dma_free_attrs" },
	{ 0x2f93810, "module_layout" },
};

MODULE_INFO(depends, "");

MODULE_ALIAS("of:N*T*Cppe,kv260-model6-dma-1.0");
MODULE_ALIAS("of:N*T*Cppe,kv260-model6-dma-1.0C*");

MODULE_INFO(srcversion, "A65FAD66F57BC78D55BA7EB");
