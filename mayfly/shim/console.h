#pragma once
#include <stdint.h>

#define FB_BASE		0xb8000000UL	/* mayfly: cont_splash_region 0xb8000000, 0x2b00000 (43MB) */
#define FB_W		1080		/* qcom,mdss_dsi_l3s_42_02_0a_dsc_cmd: 0x438 x 0x960 */
#define FB_H		2400
/* 实测：1088 的 stride 会把文字糊成横条纹（每行错 8 px，累积上千像素），
 * 说明 ABL 的 splash 缓冲就是按 1080 逐行紧密排布的。 */
#define FB_STRIDE	(FB_W * 4)	/* a8r8g8b8 */

#define RED	0xffff0000U
#define BLUE	0xff0000a0U
#define WHITE	0xffffffffU
#define YELLOW	0xffffff00U
#define GREEN	0xff00ff00U

extern volatile uint32_t *con_fb;

void con_clear(uint32_t bg);
void con_skip(void);
/* Draw a large centred banner (ASCII art from the 8x16 font) and leave the
 * text cursor below it. scale is the font pixel multiplier. */
void con_banner(const char *text, const char *sub, uint32_t fg, uint32_t bg, int scale);
void con_str(const char *label, const char *s);
void con_hex(const char *label, uint64_t v);
/* label, then "a=xxxxxxxx b=xxxxxxxx" style pairs of 32-bit values */
void con_hex2(const char *label, const char *a, uint32_t va, const char *b, uint32_t vb);
