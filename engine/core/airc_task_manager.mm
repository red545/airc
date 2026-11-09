// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// P20d: Chromium's task manager model (the data behind Chrome's Task Manager window) for the app's own window.
#import "airc/core/public/Airc.h"

#include <algorithm>
#include <cmath>
#include <memory>

#include "base/no_destructor.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/task_manager/providers/task.h"
#include "chrome/browser/task_manager/task_manager_interface.h"
#include "chrome/browser/task_manager/task_manager_observer.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_process_host.h"

namespace {
using Handler = void (^)(NSArray<NSDictionary<NSString*, id>*>*);

NSString* KindOf(task_manager::Task::Type type) {
  switch (type) {
    case task_manager::Task::BROWSER: return @"browser";
    case task_manager::Task::GPU: return @"gpu";
    case task_manager::Task::UTILITY: return @"utility";
    case task_manager::Task::RENDERER: return @"renderer";
    case task_manager::Task::EXTENSION: return @"extension";
    case task_manager::Task::GUEST: return @"guest";
    case task_manager::Task::DEDICATED_WORKER:
    case task_manager::Task::SHARED_WORKER:
    case task_manager::Task::SERVICE_WORKER: return @"worker";
    default: return @"other";
  }
}

// One observer at a time: the app's window is the only consumer. Sampling stops when it's removed, so a closed
// Task Manager costs nothing.
class Observer : public task_manager::TaskManagerObserver {
 public:
  Observer(base::TimeDelta interval, Handler handler)
      : TaskManagerObserver(interval, task_manager::REFRESH_TYPE_CPU | task_manager::REFRESH_TYPE_MEMORY_FOOTPRINT |
                                          task_manager::REFRESH_TYPE_NETWORK_USAGE),
        handler_([handler copy]) {}

  void OnTasksRefreshed(const task_manager::TaskIdList& ids) override {
    auto* manager = observed_task_manager();
    if (!manager) return;
    NSMutableArray* tasks = [NSMutableArray arrayWithCapacity:ids.size()];
    // The TaskManagerEndProcessEnabled policy, as Chrome's window honours it.
    const bool end_process_enabled = task_manager::TaskManagerInterface::IsEndProcessEnabled();
    for (const auto id : ids) {
      NSMutableDictionary* task = [NSMutableDictionary dictionary];
      task[@"taskID"] = @(id);
      task[@"rootTaskID"] = @(manager->GetRootTaskId(id));
      task[@"title"] = base::SysUTF16ToNSString(manager->GetTitle(id));
      task[@"kind"] = KindOf(manager->GetType(id));
      task[@"pid"] = @(manager->GetProcessId(id));
      // SessionTabHelper's id, the same as AircTab.tabId: the app knows the tab, its profile and whether it's private.
      const SessionID tab = manager->GetTabId(id);
      if (tab.is_valid()) task[@"tabId"] = @(tab.id());
      task[@"profileName"] = base::SysUTF16ToNSString(manager->GetProfileName(id));
      // Renderer processes never mix profiles, so a private window's pages, frames and workers are on processes of
      // its off-the-record context. The app shows those without title or URL outside their own window.
      auto* host = content::RenderProcessHost::FromID(manager->GetChildProcessUniqueId(id));
      task[@"offTheRecord"] = @(host && host->GetBrowserContext()->IsOffTheRecord());
      const double cpu = manager->GetPlatformIndependentCPUUsage(id);
      if (!std::isnan(cpu)) task[@"cpu"] = @(cpu);
      if (const auto memory = manager->GetMemoryFootprintUsage(id)) task[@"memory"] = @(memory->InBytes());
      task[@"network"] = @(manager->GetNetworkUsage(id).InBytes());
      task[@"killable"] = @(end_process_enabled && manager->IsTaskKillable(id));
      [tasks addObject:task];
    }
    handler_(tasks);
  }

 private:
  Handler handler_;
};

std::unique_ptr<Observer>& Current() {
  static base::NoDestructor<std::unique_ptr<Observer>> observer;
  return *observer;
}
}  // namespace

@implementation AircEngine (TaskManager)
+ (void)observeTasksEvery:(NSTimeInterval)interval handler:(Handler)handler {
  auto* manager = task_manager::TaskManagerInterface::GetTaskManager();
  auto& current = Current();
  if (current) {
    manager->RemoveObserver(current.get());
    current.reset();
  }
  if (!handler) return;
  current = std::make_unique<Observer>(base::Seconds(std::max(0.5, interval)), handler);
  manager->AddObserver(current.get());
}

+ (BOOL)endTask:(int64_t)taskID {
  auto* manager = task_manager::TaskManagerInterface::GetTaskManager();
  if (!task_manager::TaskManagerInterface::IsEndProcessEnabled() || !manager->IsTaskValid(taskID) ||
      !manager->IsTaskKillable(taskID)) {
    return NO;
  }
  return manager->KillTask(taskID);
}
@end
