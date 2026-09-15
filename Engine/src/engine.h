#pragma once

#include "qbdi_trace.h"

/* 32 个固定 trampoline 的函数指针表(tramp.c 定义) */
extern const void *g_tramps[TRACE_MAX_TARGETS];

/* 引擎入口:Tweak.x 的 %ctor 调用。
 * 读 JSON 配置 → 当前 app 匹配则按每条目延迟装 hook;否则空转返回。 */
void engine_start(void);
