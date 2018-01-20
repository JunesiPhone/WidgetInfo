WidgetInfo
----

Hooks into iWidgets to provide battery, ram, music, calendar events, reminders from reminders app, and weather directly from iOS. It does this by injecting global variables which are defined in the ExampleWidget. When said info is updated it will call a main function mainUpdate(type) the parameter passed describes what info was changed and therefore a developer can update those dom elements without the need for timers. Widgets must use the methods shown in the ExampleWidget to receive this info. This will not automatically fix old widgets.

iOS Calls
----

With communication from iOS to the iWidget, the only thing missing was calling iOS from the iWidget. This is handled by hooking iWidgets hitTest: method. Calls that are translated are defined in the ExampleWidget.

Latest version <a href="https://www.dropbox.com/s/nxrtu1pzcihgmvp/widgetinfo.deb?dl=0">here</a>.

Credits
----

Andrew Wiik <a href="https://twitter.com/Andywiik">@Andywiik</a> for his implementation of getting weather condition strings from the weather framework. Makes life so much easier for iWidget developers.

Matt Clark <a href="https://twitter.com/_Matchstic">@_Matchstic</a> for his amazing work on <a href="https://github.com/Matchstic/InfoStats2">InfoStats2</a> the roadmap I followed to create FrontPage which has also lead to WidgetInfo.

