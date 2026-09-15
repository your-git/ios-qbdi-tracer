// TracerEngine 入口:substrate 载入到任意 app 时跑构造器。
// engine_start() 内部按 bundleId 匹配配置,不匹配就空转返回。
// 不用 Logos %ctor(Apple clang 21+ 无法编译其 __unused 参数),用标准构造器。
#import "engine.h"

__attribute__((constructor))
static void TracerEngineInit(void) {
    engine_start();
}
