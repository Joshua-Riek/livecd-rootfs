#!/usr/bin/python
import os,sys
import atexit

class Mount:
    def __init__(self):
	atexit.register(self.cleanup,self)
	self.mounts={}
	self.losetupDev=None

    def addMount(self,name):
	self.mounts[name]=1

    def losetup(self,name):
	if self.losetupDev==None:
	    self.losetupDev=os.popen("losetup -f").read().strip()
	os.system("losetup %s %s" % (self.losetupDev,name)

    def unLosetup(self):
	os.system("losetup -d %s"%self.losetupDev)

    def cleanup(self):
	# XXX - need to unmount stuff
	pass
