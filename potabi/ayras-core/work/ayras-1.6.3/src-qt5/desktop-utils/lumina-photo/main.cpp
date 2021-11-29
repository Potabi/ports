//===========================================
//  Lumina-DE source code
//  Copyright (c) 2016, Ken Moore
//  Available under the 3-clause BSD license
//  See the LICENSE file for full details
//===========================================
#include <QApplication>
#include <QDebug>

#include <LUtils.h>
#include <LuminaSingleApplication.h>
#include <LuminaThemes.h>

#include "mainUI.h"

int main (int argc, char *argv[])
{
    LTHEME::LoadCustomEnvSettings ();
    LSingleApplication a (argc, argv, "l-photo");
    if (!a.isPrimaryProcess ())
    {
        return 0;
    }
    // Now go ahead and setup the app
    QStringList args;
    for (int i = 1; i < argc; i++)
    {
        if (QString (argv[i]).startsWith ("--"))
        {
            args << QString (argv[i]);
        }
        else
        {
            args << LUtils::PathToAbsolute (QString (argv[i]));
        }
    }
    // Now start the window
    MainUI W;
    W.show ();
    W.loadArguments (args);
    return a.exec ();
}
