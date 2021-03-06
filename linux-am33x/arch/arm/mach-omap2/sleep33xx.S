/*
 * Low level suspend code for AM33XX SoCs
 *
 * Copyright (C) 2012 Texas Instruments Incorporated - http://www.ti.com/
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation version 2.
 *
 * This program is distributed "as is" WITHOUT ANY WARRANTY of any
 * kind, whether express or implied; without even the implied warranty
 * of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#include <linux/linkage.h>
#include <linux/init.h>
#include <asm/memory.h>
#include <asm/assembler.h>
#include <mach/io.h>
#include <plat/emif.h>
#include "cm33xx.h"

#include <plat/emif.h>
#include <plat/sram.h>

#include "cm33xx.h"
#include "pm33xx.h"
#include "prm33xx.h"
#include "control.h"

/*
 * We should probably pass in the virtual address of PRCM, Control and EMIF
 * along with the physical addresses, load it into the registers
 * and then continue.
 *
 * This routine is executed from internal RAM and expects the memory type and
 * other DDR configuration values which are different across different memory
 * types to be passed in r0 _strictly_ in following order:
 * 1) memory_type [r0]
 * 2) susp_vtp_ctrl_val [r1]
 *
 * The code loads these values taking r0 value as reference to the array in
 * registers starting from r0, i,e memory_type goes to r0 and susp_vtp_ctrl_val
 * goes to r1. These are then saved into memory locations before proceeding
 * with the sleep sequence and hence registers r0,r1 can still be used in the
 * rest of the sleep code.
 *
 * mem_type is used to decide different suspend-resume sequences for DDR2
 * and DDR3.
 */
	.align 3
ENTRY(am33xx_do_wfi)
	stmfd	sp!, {r4 - r11, lr}	@ save registers on stack

	.macro	pll_bypass, name, clk_mode_addr, idlest_addr, pll_mode
pll_bypass_\name:
	ldr	r0, \clk_mode_addr
	ldr	r1, [r0]
	str	r1, clk_mode_\pll_mode
	bic	r1, r1, #(7 << 0)
	orr	r1, r1, #0x5
	str	r1, [r0]
	ldr	r0, \idlest_addr
wait_pll_bypass_\name:
	ldr	r1, [r0]
	tst	r1, #0x0
	bne	wait_pll_bypass_\name
	.endm

	.macro	pll_lock, name, clk_mode_addr, idlest_addr, pll_mode
pll_lock_\name:
	ldr	r0, \clk_mode_addr
	ldr	r1, clk_mode_\pll_mode
	str	r1, [r0]
	and	r1, r1, #0x7
	cmp	r1, #0x7
	bne	pll_mode_restored_\name
	ldr	r0, \idlest_addr
wait_pll_lock_\name:
	ldr	r1, [r0]
	ands	r1, #0x1
	beq	wait_pll_lock_\name
pll_mode_restored_\name:
	nop
	.endm

	.macro	ddr_self_refresh, num
ddr_self_refresh_\num:
	add	r1, r0, #EMIF4_0_SDRAM_MGMT_CTRL
	ldr	r2, [r1]
	orr	r2, r2, #0xa0		@ a reasonable delay for entering SR
	str	r2, [r1, #0]
	str	r2, [r1, #4]		@ write to shadow register also

	ldr	r2, ddr_start		@ do a dummy access to DDR
	ldr	r3, [r2, #0]
	ldr	r3, [r1, #0]
	orr	r3, r3, #0x200		@ now set the LP MODE to Self-Refresh
	str	r3, [r1, #0]

	mov	r1, #0x1000		@ Give some time for system to enter SR
wait_sr_\num:
	subs	r1, r1, #1
	bne	wait_sr_\num
	.endm

	.macro	wait_sdram_config ,num
wait_sdram_config_\num:
	mov	r0, #0x100
wait_sc_\num:
	subs	r0, r0 ,#1
	bne	wait_sc_\num
	.endm

	mov	r8, r0			@ same arg list passed to us

	/* EMIF config for low power mode */
	ldr	r0, emif_addr_func
	blx	r0

	str	r0, emif_addr_virt

	/* This ensures isb */
	ldr	r0, dcache_flush
	blx	r0

	/* Same as v7_flush_icache_all - saving a branch */
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0	@ I+BTB cache invalidate

	ldm	r8, {r0-r1}		@ gather values passed

	/* Save the values passed */
	str	r0, mem_type
	str	r1, susp_vtp_ctrl_val

	ldr	r0, emif_addr_virt

	/* Save EMIF configuration */
	ldr	r1, [r0, #EMIF4_0_SDRAM_CONFIG]
	str	r1, emif_sdcfg_val
	ldr	r1, [r0, #EMIF4_0_SDRAM_REF_CTRL]
	str	r1, emif_ref_ctrl_val
	ldr	r1, [r0, #EMIF4_0_SDRAM_TIM_1]
	str	r1, emif_timing1_val
	ldr	r1, [r0, #EMIF4_0_SDRAM_TIM_2]
	str	r1, emif_timing2_val
	ldr	r1, [r0, #EMIF4_0_SDRAM_TIM_3]
	str	r1, emif_timing3_val
	ldr	r1, [r0, #EMIF4_0_SDRAM_MGMT_CTRL]
	str	r1, emif_pmcr_val
	ldr	r1, [r0, #EMIF4_0_SDRAM_MGMT_CTRL_SHADOW]
	str	r1, emif_pmcr_shdw_val
	ldr	r1, [r0, #EMIF4_0_ZQ_CONFIG]
	str	r1, emif_zqcfg_val
	ldr	r1, [r0, #EMIF4_0_DDR_PHY_CTRL_1]
	str	r1, emif_rd_lat_val

	/* Ensure that all the writes to DDR leave the A8 */
	dsb
	dmb
	isb

	/* Different sleep sequences for DDR2 and DDR3 */
	ldr	r6, mem_type
	cmp	r6, #MEM_TYPE_DDR2
	beq	ddr2_susp_seq

	/* DDR3 suspend sequence */

	/* For DDR3, hold DDR_RESET high via control module */
	ldr	r2, virt_ddr_io_ctrl
	ldr	r1, [r2]
	mov	r3,#1
	mov	r3,r3,lsl #31
	orr	r1,r1,r3		@ set ddr3_rst_def_val
	str	r1, [r2]

	ddr_self_refresh	1

	/* Weak pull down for macro DATA0 */
	ldr	r1, virt_ddr_data0_ioctrl
	ldr	r2, susp_io_pull_data
	str	r2, [r1]

	/* Weak pull down for macro DATA1 */
	ldr	r1, virt_ddr_data1_ioctrl
	ldr	r2, susp_io_pull_data
	str	r2, [r1]

	/* Weak pull down for macro CMD0 */
	ldr	r1, virt_ddr_cmd0_ioctrl
	ldr	r2, susp_io_pull_cmd1
	str	r2, [r1]

	/* Weak pull down for macro CMD1 */
	ldr	r1, virt_ddr_cmd1_ioctrl
	ldr	r2, susp_io_pull_cmd1
	str	r2, [r1]

	/*
	 * Weak pull down for macro CMD2
	 * exception: keep DDR_RESET pullup
	 */
	ldr	r1, virt_ddr_cmd2_ioctrl
	ldr	r2, susp_io_pull_cmd2
	str	r2, [r1]

	/* Disable VTP */
	ldr	r1, virt_ddr_vtp_ctrl
	ldr	r2, susp_vtp_ctrl_val
	str	r2, [r1]

	/* Put IO in mDDR (cmos) mode */
	ldr	r0, virt_ddr_io_ctrl
	ldr	r1, [r0]
	mov	r2, #(0x1 << 28)
	orr	r3,r2,r1
	str	r3, [r0]

	/* Disable EMIF at this point */
	ldr	r1, virt_emif_clkctrl
	ldr	r2, [r1]
	bic	r2, r2, #(3 << 0)
	str	r2, [r1]

	ldr	r1, virt_emif_clkctrl
wait_emif_disable3:
	ldr	r2, [r1]
	ldr	r3, module_disabled_val
	cmp	r2, r3
	bne	wait_emif_disable3

	/* Enable SRAM LDO ret mode */
	ldr	r0, virt_sram_ldo_addr
	ldr	r1, [r0]
	orr	r1, #1
	str	r1, [r0]

	b	put_pll_bypass

ddr2_susp_seq:
	ddr_self_refresh	2

	/* Disable EMIF at this point */
	ldr	r1, virt_emif_clkctrl
	ldr	r2, [r1]
	bic	r2, r2, #(3 << 0)
	str	r2, [r1]

	ldr	r1, virt_emif_clkctrl
wait_emif_disable:
	ldr	r2, [r1]
	ldr	r3, module_disabled_val
	cmp	r2, r3
	bne	wait_emif_disable

	/* DDR3 reset override and mDDR mode selection */
	ldr	r0, virt_ddr_io_ctrl
	mov	r1, #(0x9 << 28)
	str	r1, [r0]

	/* Weak pull down for DQ, DM */
	ldr	r1, virt_ddr_io_pull1
	ldr	r2, susp_io_pull_data
	str	r2, [r1]

	ldr	r1, virt_ddr_io_pull2
	ldr	r2, susp_io_pull_data
	str	r2, [r1]

	/* Disable VTP */
	ldr	r1, virt_ddr_vtp_ctrl
	ldr	r2, susp_vtp_ctrl_val
	str	r2, [r1]

	/* Enable SRAM LDO ret mode */
	ldr	r0, virt_sram_ldo_addr
	ldr	r1, [r0]
	orr	r1, #1
	str	r1, [r0]

put_pll_bypass:
	/* Put the PLLs in bypass mode */
	pll_bypass	core, virt_core_clk_mode, virt_core_idlest, core_val
	pll_bypass	ddr, virt_ddr_clk_mode, virt_ddr_idlest, ddr_val
	pll_bypass	disp, virt_disp_clk_mode, virt_disp_idlest, disp_val
	pll_bypass	per, virt_per_clk_mode, virt_per_idlest, per_val
	pll_bypass	mpu, virt_mpu_clk_mode, virt_mpu_idlest, mpu_val

	dsb
	dmb
	isb

	wfi
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

	/* We come here in case of an abort */

	/* Relock the PLLs */
	pll_lock	mpu_abt, virt_mpu_clk_mode, virt_mpu_idlest, mpu_val
	pll_lock	per_abt, virt_per_clk_mode, virt_per_idlest, per_val
	pll_lock	disp_abt, virt_disp_clk_mode, virt_disp_idlest, disp_val
	pll_lock	ddr_abt, virt_ddr_clk_mode, virt_ddr_idlest, ddr_val
	pll_lock	core_abt, virt_core_clk_mode, virt_core_idlest, core_val

	ldr	r6, mem_type
	cmp	r6, #MEM_TYPE_DDR2
	beq	ddr2_resume_seq_abt

	/* DDR3 resume path */

	/* Disable SRAM LDO ret mode */
	ldr	r0, virt_sram_ldo_addr
	ldr	r1, [r0]
	bic	r1, #1
	str	r1, [r0]

	/* Enable EMIF */
	ldr	r1, virt_emif_clkctrl
	mov	r2, #0x2
	str	r2, [r1]
wait_emif_enable3:
	ldr	r3, [r1]
	cmp	r2, r3
	bne	wait_emif_enable3

	/* Take out IO of mDDR mode */
	ldr	r0, virt_ddr_io_ctrl
	ldr	r1, [r0]
	bic	r1, r1, #(1 << 28)
	str	r1, [r0]

	/* Enable VTP */
config_vtp_abt3:
	ldr	r0, virt_ddr_vtp_ctrl
	ldr	r1, [r0]
	mov	r2, #0x0	@ clear the register
	str	r2, [r0]
	mov	r2, #0x6	@ write the filter value
	str	r2, [r0]

	ldr	r1, [r0]
	ldr	r2, vtp_enable	@ set the enable bit
	orr	r2, r2, r1
	str	r2, [r0]

	ldr	r1, [r0]	@ toggle the CLRZ bit
	bic	r1, #1
	str	r1, [r0]

	ldr	r1, [r0]
	orr	r1, #1
	str	r1, [r0]

poll_vtp_ready_abt3:
	ldr	r1, [r0]	@ poll for VTP ready
	tst	r1, #(1 << 5)
	beq	poll_vtp_ready_abt3

	/*	Disable the pull for CMD2 */
	ldr	r1, virt_ddr_cmd2_ioctrl
	ldr	r2, resume_io_pull_cmd
	str	r2, [r1]
	/*	Disable the pull for CMD1 */
	ldr	r1, virt_ddr_cmd1_ioctrl
	ldr	r2, resume_io_pull_cmd
	str	r2, [r1]
	/*	Disable the pull for CMD0 */
	ldr	r1, virt_ddr_cmd0_ioctrl
	ldr	r2, resume_io_pull_cmd
	str	r2, [r1]
	/*	Disable the pull for DATA1 */
	ldr	r1, virt_ddr_data1_ioctrl
	ldr	r2, resume_io_pull_data
	str	r2, [r1]
	/*	Disable the pull for DATA0 */
	ldr	r1, virt_ddr_data0_ioctrl
	ldr	r2, resume_io_pull_data
	str	r2, [r1]

	wait_sdram_config	1

	b	emif_self_refresh_dis

	/* DDR2 resume path */
ddr2_resume_seq_abt:
	/* Disable SRAM LDO ret mode */
	ldr	r0, virt_sram_ldo_addr
	ldr	r1, [r0]
	bic	r1, #1
	str	r1, [r0]

	/* Restore the pull for DQ, DM */
	ldr	r1, virt_ddr_io_pull1
	ldr	r2, resume_io_pull_data
	str	r2, [r1]

	ldr	r1, virt_ddr_io_pull2
	ldr	r2, resume_io_pull_data
	str	r2, [r1]

	/* Enable EMIF */
	ldr	r1, virt_emif_clkctrl
	mov	r2, #0x2
	str	r2, [r1]
wait_emif_enable:
	ldr	r3, [r1]
	cmp	r2, r3
	bne	wait_emif_enable

	/* Enable VTP */
config_vtp_abt:
	ldr	r0, virt_ddr_vtp_ctrl
	ldr	r1, [r0]
	mov	r2, #0x0	@ clear the register
	str	r2, [r0]
	mov	r2, #0x6	@ write the filter value
	str	r2, [r0]

	ldr	r1, [r0]
	ldr	r2, vtp_enable	@ set the enable bit
	orr	r2, r2, r1
	str	r2, [r0]

	ldr	r1, [r0]	@ toggle the CLRZ bit
	bic	r1, #1
	str	r1, [r0]

	ldr	r1, [r0]
	orr	r1, #1
	str	r1, [r0]

poll_vtp_ready_abt:
	ldr	r1, [r0]	@ poll for VTP ready
	tst	r1, #(1 << 5)
	beq	poll_vtp_ready_abt

	/* DDR3 reset override and mDDR mode clear */
	ldr	r0, virt_ddr_io_ctrl
	mov	r1, #0
	str	r1, [r0]

emif_self_refresh_dis:
	/* Disable EMIF self-refresh */
	ldr	r0, emif_addr_virt
	add	r0, r0, #EMIF4_0_SDRAM_MGMT_CTRL
	ldr	r1, [r0]
	bic	r1, r1, #(0x7 << 8)
	str	r1, [r0]
	str	r1, [r0, #4]

	mov	r0, #7
	ldmfd	sp!, {r4 - r11, pc}	@ restore regs and return

ENTRY(am33xx_resume_offset)
	.word . - am33xx_do_wfi

ENTRY(am33xx_resume_from_deep_sleep)
	/* Take the PLLs out of LP_BYPASS */
	pll_lock	mpu, phys_mpu_clk_mode, phys_mpu_idlest, mpu_val
	pll_lock	per, phys_per_clk_mode, phys_per_idlest, per_val
	pll_lock	disp, phys_disp_clk_mode, phys_disp_idlest, disp_val
	pll_lock	ddr, phys_ddr_clk_mode, phys_ddr_idlest, ddr_val
	pll_lock	core, phys_core_clk_mode, phys_core_idlest, core_val

	ldr	r6, mem_type
	cmp	r6, #MEM_TYPE_DDR2
	beq	ddr2_resume_seq

	/* DDR3 resume path */

	/* Disable SRAM LDO ret mode */
	ldr	r0, phys_sram_ldo_addr
	ldr	r1, [r0]
	bic	r1, #1
	str	r1, [r0]

	/* TODO: Put EMIF enable here */

	/* Take out IO of mDDR mode */
	ldr	r0, phys_ddr_io_ctrl
	ldr	r1, [r0]
	bic	r1, r1, #(1 << 28)
	str	r1, [r0]

config_vtp3:
	ldr	r0, phys_ddr_vtp_ctrl
	ldr	r1, [r0]
	mov	r2, #0x0	@ clear the register
	str	r2, [r0]
	mov	r2, #0x6	@ write the filter value
	str	r2, [r0]

	ldr	r1, [r0]
	ldr	r2, vtp_enable	@ set the enable bit
	orr	r2, r2, r1
	str	r2, [r0]

	ldr	r1, [r0]	@ toggle the CLRZ bit
	bic	r1, #1
	str	r1, [r0]

	ldr	r1, [r0]
	orr	r1, #1
	str	r1, [r0]
poll_vtp_ready3:
	ldr	r1, [r0]	@ poll for VTP ready
	tst	r1, #(1 << 5)
	beq	poll_vtp_ready3

	/*	Disable the pull for CMD2 */
	ldr	r1, phys_ddr_cmd2_ioctrl
	ldr	r2, resume_io_pull_cmd
	str	r2, [r1]
	/*	Disable the pull for CMD1 */
	ldr	r1, phys_ddr_cmd1_ioctrl
	ldr	r2, resume_io_pull_cmd
	str	r2, [r1]
	/*	Disable the pull for CMD0 */
	ldr	r1, phys_ddr_cmd0_ioctrl
	ldr	r2, resume_io_pull_cmd
	str	r2, [r1]
	/*	Disable the pull for DATA1 */
	ldr	r1, phys_ddr_data1_ioctrl
	ldr	r2, resume_io_pull_data
	str	r2, [r1]
	/*	Disable the pull for DATA0 */
	ldr	r1, phys_ddr_data0_ioctrl
	ldr	r2, resume_io_pull_data
	str	r2, [r1]

	wait_sdram_config	2

	b	config_emif_timings

	/* DDR2 resume path */
ddr2_resume_seq:
	/* Disable SRAM LDO ret mode */
	ldr	r0, phys_sram_ldo_addr
	ldr	r1, [r0]
	bic	r1, #1
	str	r1, [r0]

	/* Restore the pull for DQ, DM */
	ldr	r1, phys_ddr_io_pull1
	ldr	r2, resume_io_pull_data
	str	r2, [r1]

	ldr	r1, phys_ddr_io_pull2
	ldr	r2, resume_io_pull_data
	str	r2, [r1]

config_vtp:
	ldr	r0, phys_ddr_vtp_ctrl
	ldr	r1, [r0]
	mov	r2, #0x0	@ clear the register
	str	r2, [r0]
	mov	r2, #0x6	@ write the filter value
	str	r2, [r0]

	ldr	r1, [r0]
	ldr	r2, vtp_enable	@ set the enable bit
	orr	r2, r2, r1
	str	r2, [r0]

	ldr	r1, [r0]	@ toggle the CLRZ bit
	bic	r1, #1
	str	r1, [r0]

	ldr	r1, [r0]
	orr	r1, #1
	str	r1, [r0]

poll_vtp_ready:
	ldr	r1, [r0]	@ poll for VTP ready
	tst	r1, #(1 << 5)
	beq	poll_vtp_ready

	/* DDR3 reset override and mDDR mode clear */
	ldr	r0, phys_ddr_io_ctrl
	mov	r1, #0
	str	r1, [r0]

config_emif_timings:
	ldr	r3, emif_phys_addr
	ldr	r4, emif_rd_lat_val
rd_lat:
	str	r4, [r3, #EMIF4_0_DDR_PHY_CTRL_1]
	str	r4, [r3, #EMIF4_0_DDR_PHY_CTRL_1_SHADOW]
timing1:
	ldr	r4, emif_timing1_val
	str	r4, [r3, #EMIF4_0_SDRAM_TIM_1]
	str	r4, [r3, #EMIF4_0_SDRAM_TIM_1_SHADOW]
timing2:
	ldr	r4, emif_timing2_val
	str	r4, [r3, #EMIF4_0_SDRAM_TIM_2]
	str	r4, [r3, #EMIF4_0_SDRAM_TIM_2_SHADOW]
timing3:
	ldr	r4, emif_timing3_val
	str	r4, [r3, #EMIF4_0_SDRAM_TIM_3]
	str	r4, [r3, #EMIF4_0_SDRAM_TIM_3_SHADOW]
sdram_ref_ctrl:
	ldr	r4, emif_ref_ctrl_val
	str	r4, [r3, #EMIF4_0_SDRAM_REF_CTRL]
	str	r4, [r3, #EMIF4_0_SDRAM_REF_CTRL_SHADOW]
pmcr:
	ldr	r4, emif_pmcr_val
	str	r4, [r3, #EMIF4_0_SDRAM_MGMT_CTRL]
pmcr_shdw:
	ldr	r4, emif_pmcr_shdw_val
	str	r4, [r3, #EMIF4_0_SDRAM_MGMT_CTRL_SHADOW]

	/*
	 * Output impedence calib needed only for DDR3
	 * but since the initial state of this will be
	 * disabled for DDR2 no harm in restoring the
	 * old configuration
	 */
zqcfg:
	ldr	r4, emif_zqcfg_val
	str	r4, [r3, #EMIF4_0_ZQ_CONFIG]

	/*
	 * A write to SDRAM CONFIG register triggers
	 * an init sequence and hence it must be done
	 * at the end
	 */
sdcfg:
	ldr	r4, emif_sdcfg_val
	str	r4, [r3, #EMIF4_0_SDRAM_CONFIG]

	/* Back from la-la-land. Kill some time for sanity to settle in */
	mov	r0, #0x1000
wait_loop2:
	subs	r0, r0, #1
	bne	wait_loop2

	/* We are back. Branch to the common CPU resume routine */
ENTRY(am33xx_resume_vector)
	ldr	pc, resume_addr

/*
 * Local variables
 */

dcache_flush:
	.word   v7_flush_dcache_all
resume_addr:
	.word	cpu_resume - PAGE_OFFSET + 0x80000000

emif_addr_func:
	.word	am33xx_get_ram_base
emif_phys_addr:
	.word	AM33XX_EMIF0_BASE

ddr_start:
	.word	PAGE_OFFSET

virt_mpu_idlest:
	.word	AM33XX_CM_IDLEST_DPLL_MPU
virt_mpu_clk_mode:
	.word	AM33XX_CM_CLKMODE_DPLL_MPU

phys_pll_mod:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD
phys_mpu_clk_mode:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_CLKMODE_DPLL_MPU_OFFSET
phys_mpu_idlest:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_IDLEST_DPLL_MPU_OFFSET

virt_core_idlest:
	.word	AM33XX_CM_IDLEST_DPLL_CORE
virt_core_clk_mode:
	.word	AM33XX_CM_CLKMODE_DPLL_CORE
phys_core_clk_mode:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_CLKMODE_DPLL_CORE_OFFSET
phys_core_idlest:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_IDLEST_DPLL_CORE_OFFSET

virt_per_idlest:
	.word	AM33XX_CM_IDLEST_DPLL_PER
virt_per_clk_mode:
	.word	AM33XX_CM_CLKMODE_DPLL_PER
phys_per_clk_mode:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_CLKMODE_DPLL_PER_OFFSET
phys_per_idlest:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_IDLEST_DPLL_PER_OFFSET

virt_disp_idlest:
	.word	AM33XX_CM_IDLEST_DPLL_DISP
virt_disp_clk_mode:
	.word	AM33XX_CM_CLKMODE_DPLL_DISP
phys_disp_clk_mode:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_CLKMODE_DPLL_DISP_OFFSET
phys_disp_idlest:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_IDLEST_DPLL_DISP_OFFSET

virt_ddr_idlest:
	.word	AM33XX_CM_IDLEST_DPLL_DDR
virt_ddr_clk_mode:
	.word	AM33XX_CM_CLKMODE_DPLL_DDR
phys_ddr_clk_mode:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_CLKMODE_DPLL_DDR_OFFSET
phys_ddr_idlest:
	.word	AM33XX_CM_BASE + AM33XX_CM_WKUP_MOD + AM33XX_CM_IDLEST_DPLL_DDR_OFFSET

virt_sram_ldo_addr:
	.word	AM33XX_PRM_LDO_SRAM_MPU_CTRL
phys_sram_ldo_addr:
	.word	AM33XX_PRM_BASE + AM33XX_PRM_DEVICE_MOD + AM33XX_PRM_LDO_SRAM_MPU_CTRL_OFFSET

virt_emif_clkctrl:
	.word	AM33XX_CM_PER_EMIF_CLKCTRL
phys_emif_clkctrl:
	.word	AM33XX_CM_BASE + AM33XX_CM_PER_MOD + AM33XX_CM_PER_EMIF_CLKCTRL_OFFSET
module_disabled_val:
	.word	0x30000

/* DDR related stuff */
virt_ddr_io_ctrl:
	.word	AM33XX_CTRL_REGADDR(0x0E04)
phys_ddr_io_ctrl:
	.word	DDR_IO_CTRL
virt_ddr_vtp_ctrl:
	.word	AM33XX_CTRL_REGADDR(0x0E0C)
phys_ddr_vtp_ctrl:
	.word	VTP0_CTRL_REG
virt_ddr_cmd0_ioctrl:
	.word	AM33XX_CTRL_REGADDR(0x1404)
phys_ddr_cmd0_ioctrl:
	.word	DDR_CMD0_IOCTRL
virt_ddr_cmd1_ioctrl:
	.word	AM33XX_CTRL_REGADDR(0x1408)
phys_ddr_cmd1_ioctrl:
	.word	DDR_CMD1_IOCTRL
virt_ddr_cmd2_ioctrl:
	.word	AM33XX_CTRL_REGADDR(0x140C)
phys_ddr_cmd2_ioctrl:
	.word	DDR_CMD2_IOCTRL
virt_ddr_data0_ioctrl:
	.word	AM33XX_CTRL_REGADDR(0x1440)
phys_ddr_data0_ioctrl:
	.word	DDR_DATA0_IOCTRL
virt_ddr_data1_ioctrl:
	.word	AM33XX_CTRL_REGADDR(0x1444)
phys_ddr_data1_ioctrl:
	.word	DDR_DATA1_IOCTRL
vtp_enable:
	.word	VTP_CTRL_ENABLE

virt_ddr_io_pull1:
	.word	AM33XX_CTRL_REGADDR(0x1440)
phys_ddr_io_pull1:
	.word	AM33XX_CTRL_BASE + (0x1440)
virt_ddr_io_pull2:
	.word	AM33XX_CTRL_REGADDR(0x1444)
phys_ddr_io_pull2:
	.word	AM33XX_CTRL_BASE + (0x1444)
virt_ddr_io_pull3:
	.word	AM33XX_CTRL_REGADDR(0x1448)
phys_ddr_io_pull3:
	.word	AM33XX_CTRL_BASE + (0x1448)

susp_io_pull_data:
	.word	0x3FF00003
susp_io_pull_cmd1:
	.word   0xFFE0018B
susp_io_pull_cmd2:
	.word   0xFFA0098B

resume_io_pull_data:
	.word	0x18B
resume_io_pull_cmd:
	.word	0x4

susp_vtp_ctrl_val:
	.word	0xDEADBEEF
mem_type:
	.word	0xDEADBEEF
emif_addr_virt:
	.word	0xDEADBEEF
emif_rd_lat_val:
	.word	0xDEADBEEF
emif_timing1_val:
	.word	0xDEADBEEF
emif_timing2_val:
	.word	0xDEADBEEF
emif_timing3_val:
	.word	0xDEADBEEF
emif_sdcfg_val:
	.word	0xDEADBEEF
emif_ref_ctrl_val:
	.word	0xDEADBEEF
emif_zqcfg_val:
	.word	0xDEADBEEF
emif_pmcr_val:
	.word	0xDEADBEEF
emif_pmcr_shdw_val:
	.word	0xDEADBEEF

/* PLL CLKMODE before suspend */
clk_mode_mpu_val:
	.word	0xDEADBEEF
clk_mode_per_val:
	.word	0xDEADBEEF
clk_mode_disp_val:
	.word	0xDEADBEEF
clk_mode_ddr_val:
	.word	0xDEADBEEF
clk_mode_core_val:
	.word	0xDEADBEEF

ENTRY(am33xx_do_wfi_sz)
	.word	. - am33xx_do_wfi
