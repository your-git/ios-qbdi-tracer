#pragma once

#include "qbdi_trace.h"

/* start / 自定义 trigger 各 32 个固定 trampoline 的函数指针表。 */
extern const void *g_tramps[TRACE_MAX_TARGETS];
extern const void *g_trigger_tramps[TRACE_MAX_TARGETS];

/* 引擎入口:Tweak.x 的 %ctor 调用。
 * 读 JSON 配置 → 当前 app 匹配则按每条目延迟装 hook;否则空转返回。 */
void engine_start(void);
