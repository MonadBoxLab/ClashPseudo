#ifndef CLASH_PSEUDO_NATIVE_BRIDGE_H
#define CLASH_PSEUDO_NATIVE_BRIDGE_H

char *native_protect(int fd);
char *native_protect_network(int fd, char *handle);
char *native_system_dns(long long request_id, char *wire, int size);
char *native_system_lookup(long long request_id, char *host, int family);
char *native_cancel_system_dns(long long request_id);
char *native_seed_geo(char *request, int size);
void native_specification_changed(long long revision, int changed);

#endif
