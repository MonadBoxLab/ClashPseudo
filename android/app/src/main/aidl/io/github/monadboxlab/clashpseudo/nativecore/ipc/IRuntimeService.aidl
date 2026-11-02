package io.github.monadboxlab.clashpseudo.nativecore.ipc;

import android.os.Bundle;
import io.github.monadboxlab.clashpseudo.nativecore.ipc.IRuntimeCallback;

interface IRuntimeService {
    void dispatch(in Bundle event, IRuntimeCallback callback);
}
