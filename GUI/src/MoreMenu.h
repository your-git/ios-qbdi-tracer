#import <UIKit/UIKit.h>

/* 左上角「更多」菜单。Trace 列表页和 Hook 列表页共用同一套,
 * 所以帮助文案也集中放在 MoreMenu.m,不再散在某一个列表页里。
 *
 * 阶段①内容:帮助 / 设置 / 切换页面。
 * 阶段③ Hook 做好后,「新增」的副本(创建·导入 Tracer/Hook)也加进这里。 */

/* 造左上角那个「三」图标按钮;点击后弹菜单。 */
UIBarButtonItem *MoreMenuBarButton(UIViewController *host);
