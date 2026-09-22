#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "config.h"      /* HookSpec / HookMod / HOOK_MAX_TARGETS */
#include "qbdi_trace.h"  /* TraceRegFile */

/* ===== Hook 运行期(用 Dobby 真实改数据) =====
 *
 * 与 Trace 完全独立:不经过 QBDI,命中后直接改寄存器/内存再原生续跑。
 * 跳板(tramp.c 的 hook_tramp_*)保存完整现场 → 调 hook_ctx_entry → 恢复现场
 * (含被本函数改过的寄存器)→ br origin。因此改寄存器能持久生效,而不是像
 * trace 那样跑完就丢。 */

/* slot → hook 跳板函数指针(engine.m 装 hook 时按 slot 取,同 g_tramps) */
extern const void *g_hook_tramps[HOOK_MAX_TARGETS];

/* 每个 hook 的 Dobby origin(续跑地址)与模块运行时基址 */
extern void    *g_hook_origin[HOOK_MAX_TARGETS];
extern uint64_t g_hook_module_base[HOOK_MAX_TARGETS];

/* 按 g_hook_count 重置运行期状态(命中计数/失败连击/停用标志)。 */
void hook_init_state(void);

/* 跳板入口:对第 idx 个 hook 应用它的修改数据,返回续跑地址(Dobby origin)。
 * 热路径 —— 每次命中都跑。别往里塞 ObjC/malloc/加锁以外的重活。 */
uint64_t hook_ctx_entry(TraceRegFile *rf, int idx);

/* hook 专用日志(独立文件 <logRoot>/hook-logs/hook_<时间戳>.log)。
 * 同时镜像到系统控制台。engine.m 装 hook 的诊断也走这里。 */
void qbdi_hook_logf(const char *fmt, ...);

/* ---- 加载期辅助(纯逻辑,阶段④自测用提取法直接编译这几个函数) ---- */

/* 把用户填的"修改内容"编码成要写入的字节。
 *   BYTES : value 是十六进制串(可带空格/:/,),按内存顺序 → payload
 *   STRING: value 的 UTF-8 字节 + 一个 0 结尾 → payload
 *   NUMBER: value 按十六进制解析成整数,检查能装进 width 位,按小端 → payload
 * 成功返回 true 并写好 mod->payload/nbytes/number/width;失败返回 false + err。 */
bool hook_encode_value(HookMod *mod, HookValType type, uint8_t width,
                       const char *value, char *err, size_t errcap);

/* 根据"修改类型 + 表达式形态"定 mod->dst,并编译地址表达式(需要时)。
 * 实现那张不对称语义表。失败返回 false + err。 */
bool hook_classify_target(HookMod *mod, const char *expr, char *err,
                          size_t errcap);
