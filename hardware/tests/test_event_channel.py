import pathlib, subprocess, tempfile
p=pathlib.Path(tempfile.mkdtemp(prefix='event-host-test-'))
files={
'lwip/sockets.h':'''#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
''',
'freertos/FreeRTOS.h':'''#include <stdint.h>
#define pdMS_TO_TICKS(n) (n)
#define pdPASS 1
''',
'freertos/task.h':'''#include <pthread.h>
#include <time.h>
#include <stdlib.h>
static uint32_t xTaskGetTickCount(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000u+t.tv_nsec/1000000; }
static void vTaskDelete(void *p) { (void)p; pthread_exit(NULL); }
static void *test_start(void *f) { ((void(*)(void*))f)(NULL);return NULL; }
static int xTaskCreatePinnedToCore(void(*f)(void*),const char*n,int s,void*a,int pri,void*out,int core) {
 (void)n;(void)s;(void)a;(void)pri;(void)out;(void)core;pthread_t t;if(pthread_create(&t,NULL,test_start,(void*)f))return 0;pthread_detach(t);return 1;
}
''',
'main.c':r'''#define _DEFAULT_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include "ap_internal.h"
#include "../bplist/bplist.h"

// Replace only crypto/advertising/media and RTSP handshake setup; event I/O is the real firmware code.
uint8_t ap_pk[32], ap_sk[64];
ap_conn *ap_mirror_owner;
bool ap_crypto_init(const uint8_t seed[32]) { (void)seed;return true; }
bool ap_mdns_start(void) { return true; }
bool ap_mirror_streaming(void) { return false; }
void ap_mirror_stop(void) {}
void ap_handle(ap_conn*c,const ap_req*r,ap_resp*s) {
 if(!strcmp(r->method,"SETUP")){c->have_aes=true;ap_mirror_owner=c;}
 ap_resp_header(s,"CSeq","1");
}
static void log_line(const char*s) { puts(s); }
static int dial(int port,const char*source) {
 int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);struct timeval tv={3,0};
 setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof tv);
 if(source){struct sockaddr_in a={.sin_family=AF_INET};inet_pton(AF_INET,source,&a.sin_addr);assert(!bind(fd,(struct sockaddr*)&a,sizeof a));}
 struct sockaddr_in a={.sin_family=AF_INET,.sin_port=htons(port)};inet_pton(AF_INET,"127.0.0.1",&a.sin_addr);
 assert(!connect(fd,(struct sockaddr*)&a,sizeof a));return fd;
}
static size_t command(int fd,char*out) {
 size_t n=0,head=0,body=0;
 for(;;){int k=recv(fd,out+n,2047-n,0);assert(k>0);n+=k;out[n]=0;
  char*end=strstr(out,"\r\n\r\n");if(end){head=end-out+4;char*cl=strstr(out,"Content-Length: ");assert(cl);body=strtoul(cl+16,NULL,10);if(n>=head+body)break;}}
 assert(strstr(out,"POST /command HTTP/1.1\r\n"));bp_reader r;int root=bp_open(&r,(uint8_t*)out+head,body);char type[40];
 assert(bp_get_string(&r,bp_dict_get(&r,root,"type"),type,sizeof type));assert(!strcmp(type,"forceKeyFrame"));return n;
}
static void wait_ready(void) {usleep(220000);assert(airplay_request_keyframe());}
static void stats(uint32_t s,uint32_t a,uint32_t f) {usleep(200000);uint32_t x,y,z;airplay_keyframe_stats(&x,&y,&z);assert(x==s&&y==a&&z==f);}
int main(void) {
 airplay_cfg cfg={.name="host test",.log=log_line};assert(airplay_start(&cfg));usleep(200000);
 assert(!airplay_request_keyframe());int rt=dial(AP_RTSP_PORT,NULL);char buf[2048];
 const char*setup="SETUP rtsp://host RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n";
 assert(send(rt,setup,strlen(setup),0)==(int)strlen(setup));assert(recv(rt,buf,sizeof buf,0)>0);
 int wrong=dial(AP_EVENT_PORT,"127.0.0.2");assert(recv(wrong,buf,sizeof buf,0)==0);close(wrong);
 int ev=dial(AP_EVENT_PORT,NULL);wait_ready();assert(!airplay_request_keyframe());command(ev,buf);
 const char*first="HTTP/1.1 200 OK\r\nCSeq: 1\r\nContent-Length: 4\r\n\r\n";
 assert(send(ev,first,12,0)==12);stats(1,0,0);assert(send(ev,first+12,strlen(first)-12,0)==(int)strlen(first)-12);
 stats(1,0,0);assert(send(ev,"\0\1\2\3",4,0)==4);stats(1,1,0);
 wait_ready();command(ev,buf);const char*bad="HTTP/1.1 500 Error\r\nCSeq: 2\r\nContent-Length: 0\r\n\r\n";
 assert(send(ev,bad,strlen(bad),0)==(int)strlen(bad));stats(2,1,1);assert(recv(ev,buf,sizeof buf,0)==0);close(ev);
 // Bad events did not close the control session; it still replies.
 assert(send(rt,setup,strlen(setup),0)==(int)strlen(setup));assert(recv(rt,buf,sizeof buf,0)>0);
 ev=dial(AP_EVENT_PORT,NULL);wait_ready();command(ev,buf);usleep(2200000);stats(3,1,2);assert(recv(ev,buf,sizeof buf,0)==0);close(ev);
 assert(!airplay_request_keyframe());airplay_drop_sessions();assert(recv(rt,buf,sizeof buf,0)==0);close(rt);
 puts("TCP event integration passed: command plist, peer restriction, split/binary ACK, reject, timeout, control survival, teardown");return 0;
}
'''}
for name,content in files.items():
 q=p/name;q.parent.mkdir(parents=True,exist_ok=True);q.write_text(content)
root=pathlib.Path(__file__).resolve().parents[1]/'hid_bridge/src'
cmd=['cc','-std=gnu11','-g','-Wall','-Wextra','-fsanitize=address,undefined','-pthread','-I'+str(p),'-I'+str(root/'airplay'),str(p/'main.c'),str(root/'airplay/rtsp.c'),str(root/'airplay/event_protocol.c'),str(root/'bplist/bplist.c'),'-o',str(p/'test')]
subprocess.run(cmd,check=True)
subprocess.run([str(p/'test')],check=True)
