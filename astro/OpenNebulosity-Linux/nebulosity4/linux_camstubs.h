/*
 linux_camstubs.h - Linux port of OpenNebulosity

 On Linux, camera drivers whose vendor SDKs only exist for Windows or macOS
 are replaced by these stand-in classes.  Each one keeps the same class name
 so the rest of Nebulosity (camera menus, scripts, preferences) compiles
 unchanged; choosing one just reports that the camera isn't supported yet.

 To bring a real driver to Linux: remove its NEB_LINUX_STUB line below,
 include its real header in camera.h, and add its .cpp to CMakeLists.txt.

 Linux port additions are under the same BSD 3-Clause license as Nebulosity.
*/
#ifndef LINUX_CAMSTUBS_H
#define LINUX_CAMSTUBS_H

#include "cam_class.h"
#include <wx/msgdlg.h>

// Opens a stand-in class; add any extra members the rest of the code
// touches, then close it with NEB_LINUX_STUB_END.
#define NEB_LINUX_STUB_BEGIN(cls, label)                                        \
class cls : public CameraType {                                                  \
public:                                                                          \
	cls() { Name = _T(label); }                                                  \
	bool Connect() {                                                             \
		wxMessageBox(wxString(_T(label)) +                                       \
			_T(" is not supported in the Linux build yet."),                     \
			_T("Camera not available"), wxOK | wxICON_INFORMATION);              \
		return true; /* true = failed to connect */                              \
	}
#define NEB_LINUX_STUB_END };
#define NEB_LINUX_STUB(cls, label) NEB_LINUX_STUB_BEGIN(cls, label) NEB_LINUX_STUB_END

// Canon live-view zoom values (from Canon EDSDK)
enum { kEdsEvfZoom_Fit = 1, kEdsEvfZoom_x5 = 5 };
// SAC7 interface types
enum { SAC7_LXUSB = 0, SAC7_PARALLEL, SAC7_SERIAL };

// Canon DSLR: settings the preferences and CR2 code read/write
enum { USBONLY = 0, DSUSB, DIGIC3_BULB, SERIAL_DIRECT, PARALLEL, DSUSB2 };
enum { LV_NONE = 0, LV_FRAME, LV_FINE, LV_BOTH };
NEB_LINUX_STUB_BEGIN(Cam_CanonDSLRClass, "Canon DSLR")
	int WBSet = 0;
	int LEAdapter = USBONLY;
	unsigned int PortAddress = 0;
	short ParallelTrigger = 0;
	bool ScaleTo16bit = true;
	int SaveLocation = 2;
	int MirrorDelay = 0;
	int LiveViewUse = LV_NONE;
	unsigned int RAWMode = 0;
	bool StartLiveView(unsigned int) { return true; }
	bool StopLiveView() { return true; }
NEB_LINUX_STUB_END

// SBIG: guide-chip interface used by the PHD link code
NEB_LINUX_STUB_BEGIN(Cam_SBIGClass, "SBIG")
	unsigned short *GuideChipData = nullptr;
	bool GuideChipActive = false;
	int GuideXSize = 0, GuideYSize = 0;
	bool ConnectGuideChip(int&, int&) { return true; }
	void DisconnectGuideChip() {}
	bool GetGuideFrame(int, int&, int&) { return true; }
NEB_LINUX_STUB_END

NEB_LINUX_STUB_BEGIN(Cam_QHY9Class, "QHY9")
	int Driver = 0;
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_QHY8ProClass, "QHY8Pro")
	bool Pro = true;
	int Driver = 0;
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_MoravianClass, "Moravian G2/G3")
	void SetWindowHeating(int) {}
NEB_LINUX_STUB_END

NEB_LINUX_STUB_BEGIN(Cam_SAC7Class, "SAC7 / StarShoot (LXUSB/parallel)")
	unsigned int Delay2 = 0;
	int Interface = SAC7_LXUSB;
NEB_LINUX_STUB_END
NEB_LINUX_STUB(Cam_SAC10Class,         "SAC10")
NEB_LINUX_STUB(Cam_SACStarShootClass,  "Orion StarShoot (original)")
NEB_LINUX_STUB_BEGIN(Cam_ArtemisClass, "Atik / Artemis")
	bool HSModel = false;
NEB_LINUX_STUB_END
NEB_LINUX_STUB(Cam_MeadeDSIClass,      "Meade DSI")
NEB_LINUX_STUB(Cam_StarfishClass,      "Fishcamp Starfish")
NEB_LINUX_STUB(Cam_SXVClass,           "Starlight Xpress")
NEB_LINUX_STUB(Cam_Q8HRClass,          "QHY8 (Q8HR)")
NEB_LINUX_STUB(Cam_QHY2PROClass,       "QHY2Pro")
NEB_LINUX_STUB_BEGIN(Cam_QHY268Class, "QHY268")
	int Model = 0;
NEB_LINUX_STUB_END
NEB_LINUX_STUB(Cam_QSI500Class,        "QSI")
NEB_LINUX_STUB_BEGIN(Cam_Opticstar335Class, "Opticstar DS-335")
	bool ICE_cam = false;
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar130Class, "Opticstar PL-130")
	bool Color_cam = false;
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar145Class, "Opticstar DS-145")
	bool Color_cam = false;
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar142Class, "Opticstar DS-142")
	bool Color_cam = false;
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar142cClass, "Opticstar DS-142C")
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar336Class, "Opticstar DS-336")
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar615Class, "Opticstar DS-615")
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB_BEGIN(Cam_Opticstar616Class, "Opticstar DS-616")
	void EnablePreview(bool) {}
NEB_LINUX_STUB_END
NEB_LINUX_STUB(Cam_QHY10Class,         "QHY10")
NEB_LINUX_STUB(Cam_QHY12Class,         "QHY12")
NEB_LINUX_STUB(Cam_QHY8LClass,         "QHY8L")
NEB_LINUX_STUB(Cam_QHYUnivClass,       "QHY (universal SDK)")
NEB_LINUX_STUB(Cam_ASCOMLateCameraClass, "ASCOM")
NEB_LINUX_STUB(Cam_ASCOMCameraClass,   "ASCOM")
NEB_LINUX_STUB(Cam_ApogeeClass,        "Apogee")
NEB_LINUX_STUB(Cam_FLIClass,           "FLI")
NEB_LINUX_STUB(Cam_AltairAstroClass,   "Altair Astro")
NEB_LINUX_STUB(Cam_WDMClass,           "Webcam (WDM)")

#endif
