package io.github.monadboxlab.clashpseudo.debug;

import android.os.Bundle;
import android.os.ParcelFileDescriptor;

/** 仅供固定 instrumentation 场景使用；正文及结果沿有界 FD 传输。 */
interface ICoreFixture {
    Bundle handshake(int protocol);
    Bundle execute(int scene, in ParcelFileDescriptor input, in ParcelFileDescriptor output);
    Bundle serviceControl(int action);
    Bundle formalRoutes(int action, long device, long inode);
    void requestExit(long admittedAt, long deadline);
}
