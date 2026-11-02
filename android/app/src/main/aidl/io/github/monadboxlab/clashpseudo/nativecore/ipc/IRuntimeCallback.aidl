package io.github.monadboxlab.clashpseudo.nativecore.ipc;

import android.os.Bundle;

oneway interface IRuntimeCallback {
    void onResult(in Bundle result);
}
