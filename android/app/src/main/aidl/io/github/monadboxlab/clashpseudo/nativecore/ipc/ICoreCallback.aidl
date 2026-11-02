package io.github.monadboxlab.clashpseudo.nativecore.ipc;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;

oneway interface ICoreCallback {
    void onStatus(in Bundle state);
    void onExited(String processId, long requestId, in ParcelFileDescriptor receipt);
}
