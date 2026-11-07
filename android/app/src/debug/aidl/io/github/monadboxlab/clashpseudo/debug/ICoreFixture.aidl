package io.github.monadboxlab.clashpseudo.debug;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;

/** Only for fixed instrumentation scenarios; content and results use bounded FD transport. */
interface ICoreFixture {
    Bundle handshake(int protocol);
    Bundle execute(int scene, in ParcelFileDescriptor input, in ParcelFileDescriptor output);
    Bundle serviceControl(int action);
    Bundle formalRoutes(int action, long device, long inode);
    void requestExit(long admittedAt, long deadline);
}
