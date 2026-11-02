package io.github.monadboxlab.clashpseudo.nativecore.ipc;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import io.github.monadboxlab.clashpseudo.nativecore.ipc.ICoreCallback;

interface ICoreService {
    Bundle handshake(int protocol, ICoreCallback callback);
    Bundle status(in Bundle identity);
    Bundle submit(in Bundle request, in ParcelFileDescriptor input, in ParcelFileDescriptor output);
    void requestExit(in Bundle request);
}
